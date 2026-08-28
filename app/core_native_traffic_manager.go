package main

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"sort"
	"strings"
	"sync"

	traffic "dropo/trafficorchestrator"
)

// NativeTrafficManager owns the single in-process packet engine. It never
// launches command interpreters, Lua runtimes or third-party bypass processes.
type NativeTrafficManager struct {
	basePath string
	logger   func(string)

	mu        sync.Mutex
	engine    *traffic.Engine
	processor *traffic.Processor
	relay     *traffic.TCPRelay
	udpRelay  *traffic.UDPRelay
	fakeIPs   *traffic.FakeIPDirectory
	plan      traffic.TrafficPlan
	activeTag string
	openCount uint64
	selective *nativeSelectiveSession
	resolver  selectiveNameResolutionLease
	proxyPAC  selectiveProxyRoutingLease
}

type nativeSelectiveSession struct {
	proxyAddress            string
	catalog                 []traffic.ServiceRule
	captureProtocolEvidence bool
}

func NewNativeTrafficManager(basePath string, logger func(string)) *NativeTrafficManager {
	return &NativeTrafficManager{basePath: basePath, logger: logger}
}

func (m *NativeTrafficManager) log(message string) {
	if m != nil && m.logger != nil {
		m.logger("[TrafficEngine] " + message)
	}
}

func (m *NativeTrafficManager) dllPath() string {
	if m == nil {
		return ""
	}
	return filepath.Join(m.basePath, "bin", "WinDivert.dll")
}

func (m *NativeTrafficManager) driverPath() string {
	if m == nil {
		return ""
	}
	return filepath.Join(m.basePath, "bin", "WinDivert64.sys")
}

func (m *NativeTrafficManager) IsInstalled() bool {
	return runtime.GOOS == "windows" && fileExists(m.dllPath()) && fileExists(m.driverPath())
}

func (m *NativeTrafficManager) ActiveTag() string {
	if m == nil {
		return ""
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.activeTag
}

// SuccessfulOpenCount reports how many times this manager successfully opened
// the single WinDivert owner. The counter intentionally survives Stop so
// lifecycle diagnostics can distinguish "never opened" from "opened and then
// became unnecessary after every service resolved to direct/VPN fallback".
func (m *NativeTrafficManager) SuccessfulOpenCount() uint64 {
	if m == nil {
		return 0
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.openCount
}

// ConfigureSelectiveSession selects the no-TUN Windows path for the next
// engine open. Configuration is retained across an in-session engine stop so
// strategy maintenance can restart the same session without widening capture.
func (m *NativeTrafficManager) ConfigureSelectiveSession(proxyAddress string, catalog []traffic.ServiceRule, captureProtocolEvidence bool) error {
	if m == nil {
		return errors.New("traffic engine manager is nil")
	}
	// Compile a representative filter before mutating manager state. The real
	// relay chooses its port at StartPlan and the exact same builder is rerun.
	if _, err := traffic.BuildSelectiveWinDivertFilterForMode(catalog, 32000, captureProtocolEvidence); err != nil {
		return fmt.Errorf("validate selective capture catalog: %w", err)
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.engine != nil || m.relay != nil || m.udpRelay != nil {
		return errors.New("cannot change Windows traffic session while the engine is active")
	}
	m.selective = &nativeSelectiveSession{
		proxyAddress:            strings.TrimSpace(proxyAddress),
		catalog:                 append([]traffic.ServiceRule(nil), catalog...),
		captureProtocolEvidence: captureProtocolEvidence,
	}
	return nil
}

func (m *NativeTrafficManager) ConfigureTUNSession() error {
	if m == nil {
		return errors.New("traffic engine manager is nil")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.engine != nil || m.relay != nil || m.udpRelay != nil {
		return errors.New("cannot change Windows traffic session while the engine is active")
	}
	m.selective = nil
	return nil
}

func (m *NativeTrafficManager) AvailableStrategies() []TransparentFreeAccessStrategy {
	if m == nil || !m.IsInstalled() {
		return nil
	}
	builtin := traffic.BuiltinStrategies()
	result := make([]TransparentFreeAccessStrategy, 0, len(builtin))
	for _, strategy := range builtin {
		if strings.HasPrefix(strategy.ID, "native-discord-") {
			continue
		}
		result = append(result, TransparentFreeAccessStrategy{
			Tag:       strategy.ID,
			Label:     strategy.Label,
			ExeName:   "WinDivert.dll",
			Platforms: []string{"windows"},
		})
	}
	return result
}

func (m *NativeTrafficManager) strategyPath(_ TransparentFreeAccessStrategy) string {
	return m.dllPath()
}

func (m *NativeTrafficManager) prepareDebugLog(tag string) (string, error) {
	if m == nil || m.basePath == "" {
		return "", errors.New("traffic engine is not initialized")
	}
	directory := filepath.Join(m.basePath, ResourcesFolder, "traffic-diagnostics")
	if err := os.MkdirAll(directory, 0755); err != nil {
		return "", err
	}
	path := filepath.Join(directory, safeFileComponent(tag)+".log")
	if err := os.WriteFile(path, nil, 0644); err != nil {
		return "", err
	}
	return path, nil
}

// StartPlan validates and atomically installs a complete plan. The first plan
// opens one WinDivert handle; later plans only swap immutable processor state.
func (m *NativeTrafficManager) StartPlan(plan traffic.TrafficPlan) error {
	if m == nil {
		return errors.New("traffic engine manager is nil")
	}
	if !m.IsInstalled() {
		return errors.New("bundled WinDivert runtime is not installed")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.engine != nil {
		if plan.Revision <= m.plan.Revision {
			plan.Revision = m.plan.Revision + 1
		}
		previous := cloneTrafficPlan(m.plan)
		overlayChanged := m.selective != nil && !sameSelectiveRoutingOverlay(previous, plan)
		if err := m.engine.ApplyPlan(plan); err != nil {
			return err
		}
		if overlayChanged {
			if err := m.resolver.Update(selectiveNameResolutionPlan{Plan: plan, Directory: m.fakeIPs}); err != nil {
				m.rollbackSelectivePlan(previous, plan.Revision)
				return fmt.Errorf("update selective name resolution: %w", err)
			}
			if err := m.proxyPAC.Update(plan); err != nil {
				m.rollbackSelectivePlan(previous, plan.Revision)
				_ = m.resolver.Update(selectiveNameResolutionPlan{Plan: m.plan, Directory: m.fakeIPs})
				return fmt.Errorf("update selective PAC routing: %w", err)
			}
			m.log(fmt.Sprintf("selective routing overlay updated; VPN domains=%d native-app hosts=%d", m.proxyPAC.DomainCount(), m.resolver.PrimedMappings()))
		}
		m.plan = plan
		m.activeTag = composedStrategyTag
		return nil
	}
	var (
		processor *traffic.Processor
		backend   *traffic.WinDivertBackend
		relay     *traffic.TCPRelay
		udpRelay  *traffic.UDPRelay
		directory *traffic.FakeIPDirectory
		err       error
	)
	if m.selective == nil {
		processor, err = traffic.NewProcessorWithIdentityResolver(plan, traffic.NewWindowsFlowIdentityResolver())
		if err == nil {
			backend, err = traffic.OpenWinDivertBackend(m.dllPath())
		}
	} else {
		var directoryErr error
		directory, directoryErr = traffic.NewFakeIPDirectory(plan)
		if directoryErr != nil {
			return fmt.Errorf("compile selective fake-IP directory: %w", directoryErr)
		}
		registry := traffic.NewTCPRedirectRegistry()
		relay, err = traffic.StartTCPRelay(registry, m.selective.proxyAddress, m.log)
		if err == nil {
			udpRegistry := traffic.NewUDPRedirectRegistry()
			udpRelay, err = traffic.StartUDPRelay(udpRegistry, m.selective.proxyAddress, relay.Port(), m.log)
			if err != nil {
				_ = relay.Close()
				relay = nil
			}
			var udpRedirector *traffic.UDPPacketRedirector
			if err == nil {
				udpRedirector, err = traffic.NewUDPPacketRedirector(udpRegistry, relay.Port())
			}
			var redirector *traffic.TCPPacketRedirector
			if err == nil {
				redirector, err = traffic.NewTCPPacketRedirector(registry, relay.Port())
			}
			if err == nil {
				var filter string
				filter, err = traffic.BuildSelectiveWinDivertFilterForMode(m.selective.catalog, relay.Port(), m.selective.captureProtocolEvidence)
				if err == nil {
					processor, err = traffic.NewProcessorWithFullSelectiveRuntime(plan, traffic.NewWindowsFlowIdentityResolver(), redirector, udpRedirector, directory)
				}
				if err == nil {
					backend, err = traffic.OpenWinDivertBackendWithFilter(m.dllPath(), filter)
				}
			}
		}
	}
	if err != nil {
		if udpRelay != nil {
			_ = udpRelay.Close()
		}
		if relay != nil {
			_ = relay.Close()
		}
		return fmt.Errorf("prepare Windows traffic engine: %w", err)
	}
	engine, err := traffic.NewEngine(backend, processor, m.log)
	if err != nil {
		_ = backend.Close()
		if udpRelay != nil {
			_ = udpRelay.Close()
		}
		if relay != nil {
			_ = relay.Close()
		}
		return err
	}
	if err := engine.Start(); err != nil {
		_ = backend.Close()
		if udpRelay != nil {
			_ = udpRelay.Close()
		}
		if relay != nil {
			_ = relay.Close()
		}
		return err
	}
	var resolver selectiveNameResolutionLease
	var proxyPAC selectiveProxyRoutingLease
	if m.selective != nil {
		resolver, err = prepareSelectiveNameResolution(plan, directory)
		if err != nil {
			_ = engine.Stop()
			if udpRelay != nil {
				_ = udpRelay.Close()
			}
			if relay != nil {
				_ = relay.Close()
			}
			return fmt.Errorf("prepare selective name resolution: %w", err)
		}
		proxyPAC, err = prepareSelectiveProxyRouting(plan, m.selective.proxyAddress)
		if err != nil {
			_ = resolver.Restore()
			_ = engine.Stop()
			if udpRelay != nil {
				_ = udpRelay.Close()
			}
			if relay != nil {
				_ = relay.Close()
			}
			return fmt.Errorf("prepare selective proxy routing: %w", err)
		}
	}
	m.engine = engine
	m.processor = processor
	m.relay = relay
	m.udpRelay = udpRelay
	m.fakeIPs = directory
	m.resolver = resolver
	m.proxyPAC = proxyPAC
	m.plan = plan
	m.activeTag = composedStrategyTag
	m.openCount++
	mode := "tun-sidecar"
	if m.selective != nil {
		mode = fmt.Sprintf("selective relay=%d protocol_evidence=%t", relay.Port(), m.selective.captureProtocolEvidence)
		if resolver != nil {
			m.log(fmt.Sprintf("selective DNS cache refreshed; primed %d native-app host(s), temporarily disabled %d conflicting hosts mapping(s)", resolver.PrimedMappings(), resolver.DisabledMappings()))
		}
		if proxyPAC != nil && proxyPAC.DomainCount() > 0 {
			m.log(fmt.Sprintf("selective PAC active for %d domain suffix(es): %s", proxyPAC.DomainCount(), proxyPAC.PACURL()))
		}
	}
	m.log(fmt.Sprintf("single WinDivert owner active; mode=%s revision=%d services=%d workNetworks=%d", mode, plan.Revision, len(plan.Services), len(plan.WorkNetworks)))
	return nil
}

func (m *NativeTrafficManager) CurrentPlan() traffic.TrafficPlan {
	if m == nil {
		return traffic.TrafficPlan{}
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	return cloneTrafficPlan(m.plan)
}

func (m *NativeTrafficManager) Counters() map[string]traffic.ServiceCounters {
	if m == nil {
		return nil
	}
	m.mu.Lock()
	processor := m.processor
	m.mu.Unlock()
	if processor == nil {
		return nil
	}
	return processor.Counters()
}

func (m *NativeTrafficManager) Stop() {
	if m == nil {
		return
	}
	m.mu.Lock()
	engine := m.engine
	processor := m.processor
	relay := m.relay
	udpRelay := m.udpRelay
	resolver := m.resolver
	proxyPAC := m.proxyPAC
	m.engine = nil
	m.processor = nil
	m.relay = nil
	m.udpRelay = nil
	m.fakeIPs = nil
	m.resolver = nil
	m.proxyPAC = nil
	m.plan = traffic.TrafficPlan{}
	m.activeTag = ""
	m.mu.Unlock()
	if engine != nil {
		if err := engine.Stop(); err != nil {
			m.log("stop error: " + err.Error())
		}
	}
	if processor != nil {
		logSelectiveServiceCounters(m.log, processor.Counters())
	}
	if proxyPAC != nil {
		if err := proxyPAC.Restore(); err != nil {
			m.log("selective PAC restore error: " + err.Error())
		} else {
			m.log("selective PAC removed and previous Windows proxy settings restored")
		}
	}
	if udpRelay != nil {
		if err := udpRelay.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
			m.log("UDP relay stop error: " + err.Error())
		}
	}
	if relay != nil {
		if err := relay.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
			m.log("relay stop error: " + err.Error())
		}
	}
	if resolver != nil {
		if err := resolver.Restore(); err != nil {
			m.log("selective name-resolution restore error: " + err.Error())
		} else {
			m.log("selective hosts mappings restored and DNS cache refreshed")
		}
	}
}

func (m *NativeTrafficManager) rollbackSelectivePlan(previous traffic.TrafficPlan, failedRevision uint64) {
	if m == nil || m.engine == nil {
		return
	}
	previous.Revision = failedRevision + 1
	if err := m.engine.ApplyPlan(previous); err != nil {
		m.log("failed to roll back selective plan: " + err.Error())
		return
	}
	m.plan = previous
}

func logSelectiveServiceCounters(log func(string), counters map[string]traffic.ServiceCounters) {
	if log == nil || len(counters) == 0 {
		return
	}
	services := make([]string, 0, len(counters))
	for service := range counters {
		services = append(services, service)
	}
	sort.Strings(services)
	for _, service := range services {
		value := counters[service]
		log(fmt.Sprintf("service=%s matched=%d transformed=%d passed=%d errors=%d", service, value.Matched, value.Transformed, value.Passed, value.Errors))
	}
}

func sameSelectivePlanScope(previous, next traffic.TrafficPlan) bool {
	return reflect.DeepEqual(selectiveServiceScopes(previous.Services), selectiveServiceScopes(next.Services)) &&
		reflect.DeepEqual(previous.WorkNetworks, next.WorkNetworks) &&
		reflect.DeepEqual(previous.DirectRules, next.DirectRules)
}

func sameSelectiveRoutingOverlay(previous, next traffic.TrafficPlan) bool {
	return reflect.DeepEqual(selectedVPNDomainSuffixes(previous), selectedVPNDomainSuffixes(next)) &&
		reflect.DeepEqual(directDomainSuffixesForPlan(previous), directDomainSuffixesForPlan(next))
}

func selectiveServiceScopes(services []traffic.ServiceRule) []traffic.ServiceRule {
	result := append([]traffic.ServiceRule(nil), services...)
	for index := range result {
		result[index].CandidateStrategyIDs = nil
		result[index].ProbeTargets = nil
		result[index].AllowVPNFallback = false
		result[index].AllowDirectFallback = false
	}
	return result
}

// StartForProbe temporarily selects one native strategy for each service that
// explicitly lists it as a candidate. Service-scoped candidates (notably
// Discord) can never leak into sibling service policies. The returned closure
// restores the exact previous immutable plan.
func (m *NativeTrafficManager) StartForProbe(strategy TransparentFreeAccessStrategy) (func(), error) {
	previous := m.CurrentPlan()
	if previous.Revision == 0 {
		return nil, errors.New("no active traffic plan")
	}
	trial := cloneTrafficPlan(previous)
	trial.Revision++
	allowedByService := make(map[string]bool, len(trial.Services))
	for _, service := range trial.Services {
		allowedByService[service.ID] = containsTrafficStrategyID(service.CandidateStrategyIDs, strategy.Tag)
	}
	changed := false
	for index := range trial.Selections {
		if allowedByService[trial.Selections[index].ServiceID] {
			trial.Selections[index].StrategyID = strategy.Tag
			changed = true
		}
	}
	if !changed {
		return nil, fmt.Errorf("strategy %q is not a candidate for any active service", strategy.Tag)
	}
	if err := m.StartPlan(trial); err != nil {
		return nil, err
	}
	return func() {
		previous.Revision = trial.Revision + 1
		if err := m.StartPlan(previous); err != nil {
			m.log("failed to restore probe plan: " + err.Error())
		}
	}, nil
}

func containsTrafficStrategyID(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func cloneTrafficPlan(plan traffic.TrafficPlan) traffic.TrafficPlan {
	copyPlan := plan
	copyPlan.Strategies = append([]traffic.TrafficStrategy(nil), plan.Strategies...)
	copyPlan.Services = append([]traffic.ServiceRule(nil), plan.Services...)
	copyPlan.Selections = append([]traffic.ServiceSelection(nil), plan.Selections...)
	copyPlan.Routes = append([]traffic.ServiceRoute(nil), plan.Routes...)
	copyPlan.WorkNetworks = append([]traffic.WorkNetworkRule(nil), plan.WorkNetworks...)
	copyPlan.DirectRules = append([]traffic.DirectRule(nil), plan.DirectRules...)
	return copyPlan
}

func safeFileComponent(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	var builder strings.Builder
	for _, character := range value {
		if (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') || character == '-' || character == '_' {
			builder.WriteRune(character)
		}
	}
	if builder.Len() == 0 {
		return "traffic"
	}
	return builder.String()
}

// StartComposedStrategy remains only as a migration guard. Any call means a
// legacy command-line composition path escaped the native plan builder.
func (m *NativeTrafficManager) StartComposedStrategy(_ string, _ []string) error {
	return errors.New("legacy command-line traffic strategies are disabled")
}
