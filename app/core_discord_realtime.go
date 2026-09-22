package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	discordRealtimePollInterval     = 2 * time.Second
	discordRealtimeDialDeadline     = 10 * time.Second
	discordRealtimeStallDeadline    = 30 * time.Second
	discordRealtimeProvenDeadline   = 18 * time.Second
	discordRealtimeInboundGrace     = 10 * time.Second
	discordRealtimeMediaWarmup      = 6 * time.Second
	discordRealtimeSwitchCooldown   = 5 * time.Second
	discordRealtimeFlowRetention    = 30 * time.Second
	discordRealtimeLearnedTTL       = 15 * time.Minute
	discordRealtimeDiagInterval     = 10 * time.Second
	discordRealtimeIdleDiagInterval = 5 * time.Minute
	discordRealtimeErrorInterval    = 30 * time.Second
	// A blocked Discord control path can prevent the voice WebSocket and UDP
	// discovery flow from appearing at all. Treating that as idle left automatic
	// mode on attempt 1 forever. Once the Discord process emits public traffic,
	// give every bounded local candidate one short observation window, then use
	// the configured subscription (or direct when no subscription exists).
	discordRealtimeNoFlowDeadline    = 10 * time.Second
	discordRealtimeActivityRetention = 45 * time.Second
	discordRealtimeMaxLocalAttempts  = 256 // explicit Zapret may exhaust the full manual catalog
	discordRealtimeMinMediaBytes     = 512
	discordRealtimeMinMediaPolls     = 3
	discordRealtimeMinUploadBytes    = 64
	// Discord's discovery reply is 74 bytes. Only a larger per-poll inbound
	// delta is media evidence; discovery/control traffic must not keep a broken
	// voice route alive or suppress another flow's failure.
	discordRealtimeMeaningfulInboundBytes = 128
	discordRealtimeStallBytes             = 1024
)

type discordRealtimeController struct {
	mu sync.Mutex

	cancel             context.CancelFunc
	session            uint64
	running            bool
	automatic          bool
	vpnFallbackAllowed bool
	profileIndex       int
	attempt            int
	fallbackVPN        bool
	initialBusy        bool
	initialReady       bool
	initialIdle        time.Time
	localTried         map[string]bool
	vpnTried           map[string]bool
	lastSwitch         time.Time
	lastMediaInbound   time.Time
	routeHealthyAt     time.Time
	lastAppActivity    time.Time
	noFlowStarted      time.Time
	lastDiagnostics    time.Time
	learnedPorts       map[int]time.Time
	learnedUDPPorts    map[int]time.Time
	learnedUDPIPs      map[string]time.Time
	flows              map[string]*discordRealtimeFlow
}

type discordRealtimeFlow struct {
	ID               string
	Network          string
	Host             string
	DestinationIP    string
	DestinationPort  int
	Process          string
	Chains           []string
	FirstSeen        time.Time
	LastSeen         time.Time
	Upload           int64
	Download         int64
	WindowStarted    time.Time
	WindowUpload     int64
	WindowDownload   int64
	MediaUpload      int64
	MediaDownload    int64
	InboundPolls     int
	FirstInbound     time.Time
	LastInbound      time.Time
	Healthy          bool
	FailureReported  bool
	Announced        bool
	LastDiagUpload   int64
	LastDiagDownload int64
}

type clashConnectionsDocument struct {
	Connections []clashConnection `json:"connections"`
}

type clashConnection struct {
	ID       string                  `json:"id"`
	Metadata clashConnectionMetadata `json:"metadata"`
	Upload   int64                   `json:"upload"`
	Download int64                   `json:"download"`
	Chains   []string                `json:"chains"`
}

type clashConnectionMetadata struct {
	Network         string      `json:"network"`
	Host            string      `json:"host"`
	DestinationIP   string      `json:"destinationIP"`
	DestinationPort interface{} `json:"destinationPort"`
	Process         string      `json:"process"`
	ProcessPath     string      `json:"processPath"`
}

type discordRealtimeAction struct {
	learnedPort    int
	learnedUDPPort int
	learnedUDPIP   string
	failure        string
	suppressed     string
	connectionID   string
	started        bool
	healthy        bool
	cancelled      bool
	mediaUpload    int64
	mediaDownload  int64
	inboundPolls   int
}

type discordRealtimeFlowDiagnostic struct {
	ID              string
	Network         string
	Host            string
	DestinationIP   string
	DestinationPort int
	Process         string
	Chains          []string
	Age             time.Duration
	StalledFor      time.Duration
	Upload          int64
	Download        int64
	UploadDelta     int64
	DownloadDelta   int64
	MediaUpload     int64
	MediaDownload   int64
	InboundPolls    int
	Healthy         bool
	FailureReported bool
	LastInboundAgo  time.Duration
}

type discordRealtimeDiagnostic struct {
	Automatic      bool
	FallbackVPN    bool
	Attempt        int
	Profile        discordRealtimeProfile
	InitialBusy    bool
	InitialReady   bool
	RouteHealthy   bool
	LastInboundAgo time.Duration
	TCPPorts       []int
	UDPPorts       []int
	UDPIPs         []string
	NewFlows       []discordRealtimeFlowDiagnostic
	Flows          []discordRealtimeFlowDiagnostic
}

func newDiscordRealtimeController() *discordRealtimeController {
	return &discordRealtimeController{
		profileIndex:    0,
		attempt:         1,
		localTried:      make(map[string]bool),
		learnedPorts:    make(map[int]time.Time),
		learnedUDPPorts: make(map[int]time.Time),
		learnedUDPIPs:   make(map[string]time.Time),
		flows:           make(map[string]*discordRealtimeFlow),
	}
}

func (c *discordRealtimeController) resetLocked() {
	c.session = 0
	c.running = false
	c.profileIndex = 0
	c.attempt = 1
	c.fallbackVPN = false
	c.initialBusy = false
	c.initialReady = false
	c.initialIdle = time.Time{}
	c.localTried = make(map[string]bool)
	c.vpnTried = make(map[string]bool)
	c.lastSwitch = time.Time{}
	c.lastMediaInbound = time.Time{}
	c.routeHealthyAt = time.Time{}
	c.lastAppActivity = time.Time{}
	c.noFlowStarted = time.Time{}
	c.lastDiagnostics = time.Time{}
	c.learnedPorts = make(map[int]time.Time)
	c.learnedUDPPorts = make(map[int]time.Time)
	c.learnedUDPIPs = make(map[string]time.Time)
	c.flows = make(map[string]*discordRealtimeFlow)
}

func (c *discordRealtimeController) ownsSession(session uint64) bool {
	if c == nil || session == 0 {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.running && c.session == session
}

// resetRouteObservationLocked starts a fresh health window after a selector
// change while preserving learned Discord endpoints and the visible initial
// check. Counters returned by Clash for the old route must not influence the
// decision for the new one.
func (c *discordRealtimeController) resetRouteObservationLocked() {
	c.initialReady = false
	c.initialIdle = time.Time{}
	c.lastMediaInbound = time.Time{}
	c.routeHealthyAt = time.Time{}
	c.flows = make(map[string]*discordRealtimeFlow)
	c.noFlowStarted = time.Time{}
	now := time.Now()
	if c.automatic && !c.fallbackVPN && !c.lastAppActivity.IsZero() && now.Sub(c.lastAppActivity) <= discordRealtimeActivityRetention {
		c.noFlowStarted = now
	}
}

func (c *discordRealtimeController) snapshot() (discordRealtimeProfile, []int, []int, []string) {
	if c == nil {
		return defaultDiscordRealtimeProfile(), nil, nil, nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	profile, ok := discordRealtimeProfileAt(c.profileIndex)
	if !ok {
		profile = defaultDiscordRealtimeProfile()
	}
	cutoff := time.Now().Add(-discordRealtimeLearnedTTL)
	ports := make([]int, 0, len(c.learnedPorts))
	for port, seen := range c.learnedPorts {
		if seen.Before(cutoff) {
			delete(c.learnedPorts, port)
			continue
		}
		ports = append(ports, port)
	}
	sort.Ints(ports)
	udpPorts := make([]int, 0, len(c.learnedUDPPorts))
	for port, seen := range c.learnedUDPPorts {
		if seen.Before(cutoff) {
			delete(c.learnedUDPPorts, port)
			continue
		}
		udpPorts = append(udpPorts, port)
	}
	sort.Ints(udpPorts)
	udpIPs := make([]string, 0, len(c.learnedUDPIPs))
	for ip, seen := range c.learnedUDPIPs {
		if seen.Before(cutoff) {
			delete(c.learnedUDPIPs, ip)
			continue
		}
		udpIPs = append(udpIPs, ip)
	}
	sort.Strings(udpIPs)
	return profile, ports, udpPorts, udpIPs
}

func (a *App) decorateDiscordRealtimeSelection(selection serviceWinwsSelection) serviceWinwsSelection {
	if !strings.EqualFold(selection.ServiceTag, "discord") {
		return selection
	}
	profile, _, _, _ := a.discordRealtime.snapshot()
	selection.DiscordRealtime = profile
	return selection
}

func (a *App) startDiscordRealtimeMonitor() {
	a.startDiscordRealtimeMonitorForSession(a.currentRouteStrategySession())
}

func (a *App) startDiscordRealtimeMonitorForSession(session uint64) {
	if runtime.GOOS != "windows" || a.discordRealtime == nil || a.storage == nil {
		return
	}
	if !a.routeStrategySessionActive(session) {
		return
	}
	controller := a.discordRealtime
	settings := a.storage.GetAppSettings()
	method := FreeAccessServiceMethod(settings, "discord")
	controller.mu.Lock()
	automatic := controller.automatic
	controller.mu.Unlock()

	hasVPN := a.discordHasVPNFallback()
	// Automatic mode normally proves the native strategy first. A cached VPN
	// decision is the safe carrier during bootstrap. Connected-session
	// validation replaces fallback cache entries before this monitor starts.
	cached := a.loadServiceStrategyCache()["discord"]
	preferVPN := discordRealtimeShouldPreferVPN(method, FreeMethodsAllowed(settings), automatic, cached, hasVPN)
	target := "direct"
	if preferVPN {
		target = discordVPNGroupTag
	}
	ctx, cancel := context.WithCancel(context.Background())
	selected := false
	if err := a.commitRouteStrategySession(session, func() error {
		controller.mu.Lock()
		if controller.cancel != nil {
			controller.cancel()
		}
		controller.cancel = cancel
		controller.session = session
		controller.running = true
		controller.mu.Unlock()
		selected = a.switchOutboundSelector(discordRealtimeGroupTag, target)
		if !selected && target == discordVPNGroupTag {
			target = "direct"
			selected = a.switchOutboundSelector(discordRealtimeGroupTag, target)
		}
		controller.mu.Lock()
		controller.fallbackVPN = selected && target == discordVPNGroupTag
		controller.mu.Unlock()
		return nil
	}); err != nil {
		cancel()
		return
	}
	if !a.discordRealtimeSessionActive(controller, session) {
		return
	}

	realtimeCandidates, realtimeCurrent := a.selectorCandidates(discordRealtimeGroupTag)
	vpnCandidates, vpnCurrent := a.selectorCandidates(discordVPNGroupTag)
	profile := defaultDiscordRealtimeProfile()
	a.writeLog(fmt.Sprintf("[DiscordRealtime] monitor started: method=%s automatic=%v preferred=%s selected=%s switch_ok=%v profile=%s", method, automatic, map[bool]string{true: "vpn-first", false: "direct"}[preferVPN], realtimeCurrent, selected, profile.Tag))
	a.writeLog(fmt.Sprintf("[DiscordRealtime][Route] realtime candidates=%v current=%s; vpn candidates=%v current=%s; web/API remains on the Discord service route", realtimeCandidates, realtimeCurrent, vpnCandidates, vpnCurrent))
	if automatic {
		a.emitDiscordRealtimeCandidate(session, "Ожидаем реальный двусторонний медиапоток Discord voice")
	}
	go a.runDiscordRealtimeMonitor(ctx, controller, session)
}

func (a *App) discordRealtimeSessionActive(controller *discordRealtimeController, session uint64) bool {
	return a.routeStrategySessionActive(session) && controller.ownsSession(session)
}

func (a *App) commitDiscordRealtimeSessionAction(session uint64, action func()) bool {
	if action == nil {
		return false
	}
	err := a.commitRouteStrategySession(session, func() error {
		if !a.discordRealtime.ownsSession(session) {
			return errRouteStrategySessionExpired
		}
		action()
		return nil
	})
	return err == nil
}

func discordRealtimeShouldPreferVPN(method string, freeMethodsAllowed, automatic bool, cached serviceStrategyCacheEntry, hasVPN bool) bool {
	if !hasVPN {
		return false
	}
	if method == FreeAccessMethodVPN {
		return true
	}
	if method == FreeAccessMethodDirect || method == FreeAccessMethodZapret {
		return false
	}
	if method == FreeAccessMethodAuto && !freeMethodsAllowed {
		return true
	}
	return method == FreeAccessMethodAuto && automatic && cached.MethodTag == FreeAccessMethodVPN
}

func (a *App) prepareDiscordRealtimeSession() {
	if a.discordRealtime == nil || a.storage == nil {
		return
	}
	controller := a.discordRealtime
	controller.mu.Lock()
	controller.resetLocked()
	settings := a.storage.GetAppSettings()
	method := FreeAccessServiceMethod(settings, "discord")
	controller.automatic = (method == FreeAccessMethodAuto && FreeMethodsAllowed(settings)) ||
		(method == FreeAccessMethodZapret && ZapretStrategyMode(settings, "discord") == ZapretStrategyModeAuto)
	controller.vpnFallbackAllowed = method == FreeAccessMethodAuto
	controller.mu.Unlock()
}

func (a *App) stopDiscordRealtimeMonitor() {
	controller := a.discordRealtime
	if controller == nil {
		return
	}
	controller.mu.Lock()
	if controller.cancel != nil {
		controller.cancel()
		controller.cancel = nil
	}
	controller.running = false
	controller.session = 0
	controller.initialBusy = false
	controller.initialIdle = time.Time{}
	controller.mu.Unlock()
	a.endBusy(discordRealtimeBusyID)
}

func (a *App) runDiscordRealtimeMonitor(ctx context.Context, controller *discordRealtimeController, session uint64) {
	ticker := time.NewTicker(discordRealtimePollInterval)
	defer ticker.Stop()
	var fetchFailures int
	var lastFetchErrorLog time.Time
	for {
		select {
		case <-ctx.Done():
			a.writeLog("[DiscordRealtime] monitor stopped")
			return
		case <-ticker.C:
			if !a.discordRealtimeSessionActive(controller, session) {
				return
			}
			now := time.Now()
			document, err := a.fetchClashConnections()
			if !a.discordRealtimeSessionActive(controller, session) {
				return
			}
			if err != nil {
				fetchFailures++
				if lastFetchErrorLog.IsZero() || now.Sub(lastFetchErrorLog) >= discordRealtimeErrorInterval {
					a.writeLog(fmt.Sprintf("[DiscordRealtime][Diagnostics] cannot read Clash connections (consecutive=%d): %v", fetchFailures, err))
					lastFetchErrorLog = now
				}
				continue
			}
			if fetchFailures > 0 {
				a.writeLog(fmt.Sprintf("[DiscordRealtime][Diagnostics] Clash connection polling recovered after %d failure(s)", fetchFailures))
				fetchFailures = 0
				lastFetchErrorLog = time.Time{}
			}
			actions := controller.observeConnections(document.Connections, now, session)
			learnedTCP := make(map[int]struct{})
			learnedUDP := make(map[int]struct{})
			learnedIPs := make(map[string]struct{})
			for _, action := range actions {
				if !a.discordRealtimeSessionActive(controller, session) {
					return
				}
				if action.started {
					a.commitDiscordRealtimeSessionAction(session, func() {
						if controller.usingVPN() {
							a.updateBusy(discordRealtimeBusyID, "Проверяем Discord voice/video/Go Live через VPN...")
						} else {
							a.updateBusy(discordRealtimeBusyID, "Проверяем Discord voice/video/Go Live через локальную стратегию...")
						}
					})
				}
				if action.learnedPort > 0 {
					learnedTCP[action.learnedPort] = struct{}{}
				}
				if action.learnedUDPPort > 0 {
					learnedUDP[action.learnedUDPPort] = struct{}{}
				}
				if action.learnedUDPIP != "" {
					learnedIPs[action.learnedUDPIP] = struct{}{}
				}
			}
			if len(learnedTCP) > 0 || len(learnedUDP) > 0 || len(learnedIPs) > 0 {
				a.handleDiscordLearnedMedia(learnedTCP, learnedUDP, learnedIPs)
			}
			for _, action := range actions {
				if !a.discordRealtimeSessionActive(controller, session) {
					return
				}
				if action.healthy {
					a.commitDiscordRealtimeHealthyStrategy(session)
					a.writeLog(fmt.Sprintf("[DiscordRealtime] sustained bidirectional Discord media confirmed (upload=%d, download=%d, inbound_polls=%d); keeping the selected strategy", action.mediaUpload, action.mediaDownload, action.inboundPolls))
					a.commitDiscordRealtimeSessionAction(session, func() { a.endBusy(discordRealtimeBusyID) })
				}
				if action.cancelled {
					a.writeLog("[DiscordRealtime] initial voice check ended because Discord no longer has an active UDP flow")
					a.commitDiscordRealtimeSessionAction(session, func() { a.endBusy(discordRealtimeBusyID) })
				}
				if action.failure != "" {
					a.handleDiscordRealtimeFailure(session, action.failure)
				}
				if action.suppressed != "" {
					a.writeLog("[DiscordRealtime][Health] ignored isolated flow failure while another established Discord UDP flow remained active: " + action.suppressed)
				}
			}
			diagnostic, summaryDue := controller.collectDiagnostics(now, session)
			for _, flow := range diagnostic.NewFlows {
				a.writeLog(formatDiscordFlowDiagnostic("opened", flow))
			}
			if summaryDue {
				a.logDiscordRealtimeDiagnostic(diagnostic)
			}
		}
	}
}

func (c *discordRealtimeController) collectDiagnostics(now time.Time, session ...uint64) (discordRealtimeDiagnostic, bool) {
	if c == nil {
		return discordRealtimeDiagnostic{}, false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(session) > 0 && (session[0] == 0 || c.session != session[0]) {
		return discordRealtimeDiagnostic{}, false
	}
	profile, ok := discordRealtimeProfileAt(c.profileIndex)
	if !ok {
		profile = defaultDiscordRealtimeProfile()
	}
	result := discordRealtimeDiagnostic{
		Automatic:    c.automatic,
		FallbackVPN:  c.fallbackVPN,
		Attempt:      c.attempt,
		Profile:      profile,
		InitialBusy:  c.initialBusy,
		InitialReady: c.initialReady,
		RouteHealthy: !c.routeHealthyAt.IsZero(),
	}
	if !c.lastMediaInbound.IsZero() {
		result.LastInboundAgo = now.Sub(c.lastMediaInbound)
	}
	cutoff := now.Add(-discordRealtimeLearnedTTL)
	for port, seen := range c.learnedPorts {
		if seen.Before(cutoff) {
			delete(c.learnedPorts, port)
			continue
		}
		result.TCPPorts = append(result.TCPPorts, port)
	}
	for port, seen := range c.learnedUDPPorts {
		if seen.Before(cutoff) {
			delete(c.learnedUDPPorts, port)
			continue
		}
		result.UDPPorts = append(result.UDPPorts, port)
	}
	for ip, seen := range c.learnedUDPIPs {
		if seen.Before(cutoff) {
			delete(c.learnedUDPIPs, ip)
			continue
		}
		result.UDPIPs = append(result.UDPIPs, ip)
	}
	sort.Ints(result.TCPPorts)
	sort.Ints(result.UDPPorts)
	sort.Strings(result.UDPIPs)
	diagnosticInterval := discordRealtimeIdleDiagInterval
	if c.initialBusy || c.hasUDPFlowLocked() {
		diagnosticInterval = discordRealtimeDiagInterval
	}
	summaryDue := c.lastDiagnostics.IsZero() || now.Sub(c.lastDiagnostics) >= diagnosticInterval
	flowIDs := make([]string, 0, len(c.flows))
	for id := range c.flows {
		flowIDs = append(flowIDs, id)
	}
	sort.Strings(flowIDs)
	for _, id := range flowIDs {
		flow := c.flows[id]
		if flow == nil {
			continue
		}
		diagnostic := discordRealtimeFlowDiagnostic{
			ID:              flow.ID,
			Network:         flow.Network,
			Host:            flow.Host,
			DestinationIP:   flow.DestinationIP,
			DestinationPort: flow.DestinationPort,
			Process:         flow.Process,
			Chains:          append([]string(nil), flow.Chains...),
			Age:             now.Sub(flow.FirstSeen),
			StalledFor:      now.Sub(flow.WindowStarted),
			Upload:          flow.Upload,
			Download:        flow.Download,
			UploadDelta:     discordCounterDelta(flow.Upload, flow.LastDiagUpload),
			DownloadDelta:   discordCounterDelta(flow.Download, flow.LastDiagDownload),
			MediaUpload:     flow.MediaUpload,
			MediaDownload:   flow.MediaDownload,
			InboundPolls:    flow.InboundPolls,
			Healthy:         flow.Healthy,
			FailureReported: flow.FailureReported,
		}
		if !flow.LastInbound.IsZero() {
			diagnostic.LastInboundAgo = now.Sub(flow.LastInbound)
		}
		if !flow.Announced {
			result.NewFlows = append(result.NewFlows, diagnostic)
			flow.Announced = true
		}
		if summaryDue {
			result.Flows = append(result.Flows, diagnostic)
			flow.LastDiagUpload = flow.Upload
			flow.LastDiagDownload = flow.Download
		}
	}
	if summaryDue {
		c.lastDiagnostics = now
	}
	return result, summaryDue
}

func (c *discordRealtimeController) hasUDPFlowLocked() bool {
	for _, flow := range c.flows {
		if flow != nil && strings.EqualFold(flow.Network, "udp") {
			return true
		}
	}
	return false
}

func discordCounterDelta(current, previous int64) int64 {
	if current < previous {
		return current
	}
	return current - previous
}

func formatDiscordFlowDiagnostic(event string, flow discordRealtimeFlowDiagnostic) string {
	host := flow.Host
	if host == "" {
		host = "-"
	}
	process := flow.Process
	if process == "" {
		process = "-"
	}
	chains := "direct/unknown"
	if len(flow.Chains) > 0 {
		chains = strings.Join(flow.Chains, " -> ")
	}
	destination := net.JoinHostPort(flow.DestinationIP, strconv.Itoa(flow.DestinationPort))
	lastInbound := "never"
	if flow.LastInboundAgo > 0 {
		lastInbound = flow.LastInboundAgo.Round(time.Second).String()
	}
	return fmt.Sprintf("[DiscordRealtime][Flow] %s id=%s process=%s network=%s host=%s destination=%s chains=%s total_up=%d total_down=%d delta_up=%d delta_down=%d media_up=%d media_down=%d inbound_polls=%d age=%s stalled=%s last_inbound=%s healthy=%v failure_reported=%v", event, flow.ID, process, flow.Network, host, destination, chains, flow.Upload, flow.Download, flow.UploadDelta, flow.DownloadDelta, flow.MediaUpload, flow.MediaDownload, flow.InboundPolls, flow.Age.Round(time.Second), flow.StalledFor.Round(time.Second), lastInbound, flow.Healthy, flow.FailureReported)
}

func (a *App) logDiscordRealtimeDiagnostic(diagnostic discordRealtimeDiagnostic) {
	realtimeCandidates, realtimeCurrent := a.selectorCandidates(discordRealtimeGroupTag)
	vpnCandidates, vpnCurrent := a.selectorCandidates(discordVPNGroupTag)
	state := "idle"
	if diagnostic.InitialBusy {
		state = "checking"
	} else if diagnostic.InitialReady {
		state = "ready"
	}
	lastInbound := "never"
	if diagnostic.LastInboundAgo > 0 {
		lastInbound = diagnostic.LastInboundAgo.Round(time.Second).String()
	}
	a.writeLog(fmt.Sprintf("[DiscordRealtime][Status] route=%s vpn_node=%s automatic=%v vpn_mode=%v state=%s route_healthy=%v last_media_inbound=%s attempt=%d/%d profile=%s active_flows=%d learned_tcp=%v learned_udp=%v learned_ips=%v realtime_candidates=%v vpn_candidates=%v", realtimeCurrent, vpnCurrent, diagnostic.Automatic, diagnostic.FallbackVPN, state, diagnostic.RouteHealthy, lastInbound, diagnostic.Attempt, discordLocalStrategyCount(), diagnostic.Profile.Tag, len(diagnostic.Flows), diagnostic.TCPPorts, diagnostic.UDPPorts, diagnostic.UDPIPs, realtimeCandidates, vpnCandidates))
	if len(diagnostic.Flows) == 0 {
		return
	}
	for _, flow := range diagnostic.Flows {
		a.writeLog(formatDiscordFlowDiagnostic("snapshot", flow))
	}
}

func (c *discordRealtimeController) currentAttempt() int {
	if c == nil {
		return 1
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.attempt < 1 {
		return 1
	}
	return c.attempt
}

func (c *discordRealtimeController) usingVPN() bool {
	if c == nil {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.fallbackVPN
}

func (a *App) fetchClashConnections() (clashConnectionsDocument, error) {
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := a.clashAPIGet(client, "/connections")
	if err != nil {
		return clashConnectionsDocument{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return clashConnectionsDocument{}, fmt.Errorf("Clash connections returned HTTP %d", resp.StatusCode)
	}
	body, err := readHTTPBodyLimited(resp.Body, defaultMaxHTTPResponseBytes)
	if err != nil {
		return clashConnectionsDocument{}, err
	}
	var document clashConnectionsDocument
	if err := json.Unmarshal(body, &document); err != nil {
		return clashConnectionsDocument{}, err
	}
	return document, nil
}

func (c *discordRealtimeController) observeConnections(connections []clashConnection, now time.Time, session ...uint64) []discordRealtimeAction {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.running || (len(session) > 0 && (session[0] == 0 || c.session != session[0])) {
		return nil
	}
	actions := make([]discordRealtimeAction, 0, 2)
	pendingFailures := make([]discordRealtimeAction, 0, 2)
	seen := make(map[string]struct{}, len(connections))
	activeDiscordUDP := false
	activeDiscordRealtime := false
	discordAppActivity := false
	for _, connection := range connections {
		if connection.ID == "" || !isDiscordConnection(connection) {
			continue
		}
		network := strings.ToLower(strings.TrimSpace(connection.Metadata.Network))
		port := clashPort(connection.Metadata.DestinationPort)
		host := normalizeDiscordHost(connection.Metadata.Host)
		if isPublicDiscordAppConnection(connection, network, port) {
			discordAppActivity = true
			c.lastAppActivity = now
		}
		if network == "tcp" && isDiscordVoiceGateway(connection, host, port) {
			activeDiscordRealtime = true
			c.noFlowStarted = time.Time{}
			if port > 0 && port != 80 && port != 443 && !isDefaultDiscordTCPPort(port) {
				if _, exists := c.learnedPorts[port]; !exists {
					c.learnedPorts[port] = now
					actions = append(actions, discordRealtimeAction{learnedPort: port, connectionID: connection.ID})
				} else {
					c.learnedPorts[port] = now
				}
			}
			seen[connection.ID] = struct{}{}
			if failure, _ := c.observeDiscordFlow(connection, network, host, port, now); failure != "" {
				pendingFailures = append(pendingFailures, discordRealtimeAction{failure: failure, connectionID: connection.ID})
			}
			continue
		}
		if network != "udp" || !isDiscordMediaUDPConnection(connection, port) {
			continue
		}
		activeDiscordUDP = true
		activeDiscordRealtime = true
		c.noFlowStarted = time.Time{}
		c.initialIdle = time.Time{}
		if port > 0 {
			if _, exists := c.learnedUDPPorts[port]; !exists {
				c.learnedUDPPorts[port] = now
				actions = append(actions, discordRealtimeAction{learnedUDPPort: port, learnedUDPIP: connection.Metadata.DestinationIP, connectionID: connection.ID})
			} else {
				c.learnedUDPPorts[port] = now
			}
		}
		if ip := net.ParseIP(strings.TrimSpace(connection.Metadata.DestinationIP)); ip != nil {
			normalizedIP := ip.String()
			if _, exists := c.learnedUDPIPs[normalizedIP]; !exists {
				c.learnedUDPIPs[normalizedIP] = now
				if len(actions) == 0 || actions[len(actions)-1].learnedUDPPort != port {
					actions = append(actions, discordRealtimeAction{learnedUDPIP: normalizedIP, connectionID: connection.ID})
				} else {
					actions[len(actions)-1].learnedUDPIP = normalizedIP
				}
			} else {
				c.learnedUDPIPs[normalizedIP] = now
			}
		}
		if !c.initialReady && !c.initialBusy && connection.Upload >= 64 {
			c.initialBusy = true
			actions = append(actions, discordRealtimeAction{started: true, connectionID: connection.ID})
		}
		seen[connection.ID] = struct{}{}
		failure, healthy := c.observeDiscordFlow(connection, network, host, port, now)
		if failure != "" {
			pendingFailures = append(pendingFailures, discordRealtimeAction{failure: failure, connectionID: connection.ID})
		}
		if !c.initialReady && healthy {
			c.initialReady = true
			c.routeHealthyAt = now
			c.initialBusy = false
			c.initialIdle = time.Time{}
			flow := c.flows[connection.ID]
			action := discordRealtimeAction{healthy: true, connectionID: connection.ID}
			if flow != nil {
				action.mediaUpload = flow.MediaUpload
				action.mediaDownload = flow.MediaDownload
				action.inboundPolls = flow.InboundPolls
			}
			actions = append(actions, action)
		}
	}
	// A missing voice flow is itself a failure signal only after the Discord app
	// has emitted public traffic. This avoids strategy churn while Discord is not
	// running, but closes the gap where DPI blocks setup before Clash can expose a
	// voice connection. Subsequent local candidates inherit the recent activity
	// window so all N attempts finish promptly instead of waiting for N new app
	// connections.
	if c.automatic && !c.fallbackVPN && !c.initialReady && !activeDiscordRealtime {
		activityRecent := !c.lastAppActivity.IsZero() && now.Sub(c.lastAppActivity) <= discordRealtimeActivityRetention
		if discordAppActivity && c.noFlowStarted.IsZero() {
			c.noFlowStarted = now
			if !c.initialBusy {
				c.initialBusy = true
				actions = append(actions, discordRealtimeAction{started: true})
			}
		}
		if !activityRecent {
			c.noFlowStarted = time.Time{}
		} else if !c.noFlowStarted.IsZero() && now.Sub(c.noFlowStarted) >= discordRealtimeNoFlowDeadline {
			c.noFlowStarted = time.Time{}
			actions = append(actions, discordRealtimeAction{failure: fmt.Sprintf("Discord app traffic was observed but no voice flow appeared within %s", discordRealtimeNoFlowDeadline)})
		}
	}
	if len(pendingFailures) > 0 {
		pendingIDs := make(map[string]struct{}, len(pendingFailures))
		pendingIncludesHealthyUDP := false
		for _, pending := range pendingFailures {
			pendingIDs[pending.connectionID] = struct{}{}
			if flow := c.flows[pending.connectionID]; flow != nil && flow.Network == "udp" && flow.Healthy {
				pendingIncludesHealthyUDP = true
			}
		}
		recentInbound := !c.routeHealthyAt.IsZero() && !c.lastMediaInbound.IsZero() && now.Sub(c.lastMediaInbound) <= discordRealtimeInboundGrace
		establishedSibling := !pendingIncludesHealthyUDP && c.hasEstablishedUDPSiblingLocked(pendingIDs)
		if recentInbound || establishedSibling {
			for _, pending := range pendingFailures {
				if flow := c.flows[pending.connectionID]; flow != nil {
					flow.FailureReported = true
				}
			}
			actions = append(actions, discordRealtimeAction{suppressed: pendingFailures[0].failure, connectionID: pendingFailures[0].connectionID})
		} else {
			pending := pendingFailures[0]
			if flow := c.flows[pending.connectionID]; flow != nil {
				flow.FailureReported = true
			}
			actions = append(actions, pending)
		}
	}
	for id, flow := range c.flows {
		if _, ok := seen[id]; ok {
			continue
		}
		if now.Sub(flow.LastSeen) >= discordRealtimeFlowRetention {
			delete(c.flows, id)
		}
	}
	// Recomposition deliberately closes Discord connections between attempts.
	// Allow the client time to retry, but never leave the UI blocked forever if
	// the user leaves the voice channel while the initial check is in progress.
	if c.initialBusy && !activeDiscordUDP {
		if c.initialIdle.IsZero() {
			c.initialIdle = now
		} else if now.Sub(c.initialIdle) >= discordRealtimeFlowRetention {
			c.initialBusy = false
			c.initialIdle = time.Time{}
			actions = append(actions, discordRealtimeAction{cancelled: true})
		}
	}
	return actions
}

func (c *discordRealtimeController) hasEstablishedUDPSiblingLocked(excluded map[string]struct{}) bool {
	for id, flow := range c.flows {
		if _, skip := excluded[id]; skip || flow == nil {
			continue
		}
		if flow.Network == "udp" && flow.Healthy {
			return true
		}
	}
	return false
}

func (c *discordRealtimeController) observeDiscordFlow(connection clashConnection, network, host string, port int, now time.Time) (string, bool) {
	flow := c.flows[connection.ID]
	if flow == nil {
		flow = &discordRealtimeFlow{
			ID:              connection.ID,
			Network:         network,
			Host:            host,
			DestinationIP:   connection.Metadata.DestinationIP,
			DestinationPort: port,
			Process:         discordProcessLabel(connection.Metadata),
			Chains:          append([]string(nil), connection.Chains...),
			FirstSeen:       now,
			LastSeen:        now,
			Upload:          connection.Upload,
			Download:        connection.Download,
			WindowStarted:   now,
			WindowUpload:    connection.Upload,
			WindowDownload:  connection.Download,
		}
		if network == "tcp" && connection.Download == 0 {
			flow.WindowUpload = 0
		}
		c.flows[connection.ID] = flow
		return "", false
	}
	flow.Process = discordProcessLabel(connection.Metadata)
	flow.Chains = append(flow.Chains[:0], connection.Chains...)
	// Clash exposes cumulative byte counters. The first inbound Discord UDP
	// packet is commonly the 74-byte IP-discovery response, so it must never be
	// accepted as proof that encrypted RTP media works. Only repeated inbound
	// progress after the first observation contributes to media health.
	if connection.Upload < flow.Upload || connection.Download < flow.Download {
		flow.WindowStarted = now
		flow.WindowUpload = connection.Upload
		flow.WindowDownload = connection.Download
		flow.MediaUpload = 0
		flow.MediaDownload = 0
		flow.InboundPolls = 0
		flow.FirstInbound = time.Time{}
		flow.LastInbound = time.Time{}
		flow.Healthy = false
		flow.FailureReported = false
	} else {
		uploadDelta := connection.Upload - flow.Upload
		downloadDelta := connection.Download - flow.Download
		if uploadDelta > 0 {
			flow.MediaUpload += uploadDelta
		}
		if downloadDelta > 0 {
			flow.LastInbound = now
			if downloadDelta >= discordRealtimeMeaningfulInboundBytes {
				flow.MediaDownload += downloadDelta
				flow.InboundPolls++
				if flow.FirstInbound.IsZero() {
					flow.FirstInbound = now
				}
			}
			if network == "udp" && downloadDelta >= discordRealtimeMeaningfulInboundBytes {
				c.lastMediaInbound = now
			}
		}
	}
	if connection.Download-flow.Download >= discordRealtimeMeaningfulInboundBytes {
		flow.WindowStarted = now
		flow.WindowUpload = connection.Upload
		flow.WindowDownload = connection.Download
		flow.FailureReported = false
	}
	flow.LastSeen = now
	flow.Upload = connection.Upload
	flow.Download = connection.Download
	if !flow.Healthy && flow.MediaUpload >= discordRealtimeMinUploadBytes &&
		flow.MediaDownload >= discordRealtimeMinMediaBytes &&
		flow.InboundPolls >= discordRealtimeMinMediaPolls &&
		!flow.FirstInbound.IsZero() && now.Sub(flow.FirstInbound) >= discordRealtimeMediaWarmup {
		flow.Healthy = true
		if network == "udp" {
			c.routeHealthyAt = now
		}
	}
	sentWithoutReply := connection.Upload - flow.WindowUpload
	if !flow.FailureReported && network == "udp" && connection.Download == 0 && connection.Upload >= 64 && now.Sub(flow.FirstSeen) >= discordRealtimeDialDeadline {
		return fmt.Sprintf("UDP %s:%d did not receive the Discord discovery response within %s", flow.DestinationIP, flow.DestinationPort, discordRealtimeDialDeadline), flow.Healthy
	}
	if !flow.FailureReported && network == "udp" && !flow.Healthy && connection.Upload >= discordRealtimeMinUploadBytes && now.Sub(flow.FirstSeen) >= discordRealtimeProvenDeadline {
		return fmt.Sprintf("UDP %s:%d never established sustained Discord media within %s (meaningful download=%d, polls=%d)", flow.DestinationIP, flow.DestinationPort, discordRealtimeProvenDeadline, flow.MediaDownload, flow.InboundPolls), false
	}
	// The voice gateway is a mostly-idle WebSocket. Once it has received any
	// bytes, an outgoing heartbeat without a matching byte delta is normal and
	// must never evict a working UDP media route.
	if network == "tcp" {
		if !flow.FailureReported && connection.Download == 0 && connection.Upload >= 64 && now.Sub(flow.FirstSeen) >= discordRealtimeDialDeadline {
			return fmt.Sprintf("TCP %s:%d did not receive a Discord voice gateway response within %s", flow.DestinationIP, flow.DestinationPort, discordRealtimeDialDeadline), flow.Healthy
		}
		return "", flow.Healthy
	}
	deadline := discordRealtimeStallDeadline
	if !c.routeHealthyAt.IsZero() {
		deadline = discordRealtimeProvenDeadline
	}
	if flow.FailureReported || sentWithoutReply < discordRealtimeStallBytes || now.Sub(flow.WindowStarted) < deadline {
		return "", flow.Healthy
	}
	return fmt.Sprintf("%s %s:%d sent %d media bytes without inbound progress for %s", strings.ToUpper(network), flow.DestinationIP, flow.DestinationPort, sentWithoutReply, deadline), flow.Healthy
}

func discordProcessLabel(metadata clashConnectionMetadata) string {
	if process := strings.TrimSpace(metadata.Process); process != "" {
		return process
	}
	return discordProcessBase(metadata.ProcessPath)
}

func isDiscordConnection(connection clashConnection) bool {
	if isDiscordProcess(connection.Metadata.Process, connection.Metadata.ProcessPath) {
		return true
	}
	host := normalizeDiscordHost(connection.Metadata.Host)
	return host == "discord.media" || strings.HasSuffix(host, ".discord.media")
}

func isDiscordProcess(process, processPath string) bool {
	for _, value := range []string{process, discordProcessBase(processPath)} {
		switch strings.ToLower(strings.TrimSpace(value)) {
		case "discord.exe", "discordcanary.exe", "discordptb.exe":
			return true
		}
	}
	return false
}

func discordProcessBase(processPath string) string {
	// Clash reports the client OS path, while CI and diagnostic parsers may run
	// on another OS. Normalize Windows separators before filepath.Base so
	// C:\...\Discord.exe remains recognizable on Linux too.
	normalized := strings.ReplaceAll(strings.TrimSpace(processPath), `\`, "/")
	return filepath.Base(normalized)
}

func isPublicDiscordAppConnection(connection clashConnection, network string, port int) bool {
	if !isDiscordProcess(connection.Metadata.Process, connection.Metadata.ProcessPath) || port <= 0 || port > 65535 {
		return false
	}
	if network != "tcp" && network != "udp" {
		return false
	}
	if network == "udp" {
		switch port {
		case 53, 67, 68, 123:
			return false
		}
	}
	ip := net.ParseIP(strings.TrimSpace(connection.Metadata.DestinationIP))
	return ip != nil && !ip.IsPrivate() && !ip.IsLoopback() && !ip.IsUnspecified() && !ip.IsMulticast()
}

func isDiscordMediaUDPConnection(connection clashConnection, port int) bool {
	if !isDiscordProcess(connection.Metadata.Process, connection.Metadata.ProcessPath) || port <= 0 || port > 65535 {
		return false
	}
	// Discord web QUIC on UDP/443 is not a voice media flow. Treating it as one
	// would both produce false health results and broaden WinDivert capture for
	// unrelated HTTPS/3 traffic on the machine.
	switch port {
	case 53, 80, 123, 443:
		return false
	}
	ip := net.ParseIP(strings.TrimSpace(connection.Metadata.DestinationIP))
	return ip != nil && !ip.IsPrivate() && !ip.IsLoopback() && !ip.IsUnspecified()
}

func normalizeDiscordHost(host string) string {
	return strings.TrimSuffix(strings.ToLower(strings.TrimSpace(host)), ".")
}

func isDiscordVoiceGateway(connection clashConnection, host string, port int) bool {
	if host == "discord.media" || strings.HasSuffix(host, ".discord.media") {
		return true
	}
	if !isDiscordProcess(connection.Metadata.Process, connection.Metadata.ProcessPath) || port <= 0 || port == 80 || port == 443 {
		return false
	}
	ip := net.ParseIP(strings.TrimSpace(connection.Metadata.DestinationIP))
	return ip != nil && !ip.IsPrivate() && !ip.IsLoopback()
}

func clashPort(value interface{}) int {
	switch typed := value.(type) {
	case float64:
		return int(typed)
	case json.Number:
		port, _ := strconv.Atoi(typed.String())
		return port
	case string:
		port, _ := strconv.Atoi(strings.TrimSpace(typed))
		return port
	case int:
		return typed
	default:
		return 0
	}
}

func isDefaultDiscordTCPPort(port int) bool {
	for _, candidate := range discordDefaultMediaTCPPorts {
		if candidate == port {
			return true
		}
	}
	return false
}

func (a *App) handleDiscordLearnedMedia(tcpPorts, udpPorts map[int]struct{}, udpIPs map[string]struct{}) {
	tcpValues := sortedIntSet(tcpPorts)
	udpValues := sortedIntSet(udpPorts)
	ipValues := sortedStringSet(udpIPs)
	classes := make([]string, 0, len(udpValues))
	for _, port := range udpValues {
		class := "observed-only"
		if port >= 19294 && port <= 19344 {
			class = "official-19294-19344"
		} else if port >= 50000 && port <= 50100 {
			class = "official-50000-50100"
		}
		classes = append(classes, fmt.Sprintf("%d:%s", port, class))
	}
	a.writeLog(fmt.Sprintf("[DiscordRealtime][Endpoint] learned tcp=%v udp=%v udp_class=%v ips=%v; the immutable native plan is updated without restarting WinDivert and encrypted RTP is never modified", tcpValues, udpValues, classes, ipValues))
}

func sortedIntSet(values map[int]struct{}) []int {
	result := make([]int, 0, len(values))
	for value := range values {
		result = append(result, value)
	}
	sort.Ints(result)
	return result
}

func sortedStringSet(values map[string]struct{}) []string {
	result := make([]string, 0, len(values))
	for value := range values {
		result = append(result, value)
	}
	sort.Strings(result)
	return result
}

func (a *App) handleDiscordRealtimeFailure(session uint64, reason string) {
	controller := a.discordRealtime
	const (
		discordFailureIgnored = iota
		discordFailureManual
		discordFailureRotateVPN
		discordFailureRotateLocal
	)
	action := discordFailureIgnored
	initialBusy := false
	if err := a.commitRouteStrategySession(session, func() error {
		if !controller.ownsSession(session) {
			return errRouteStrategySessionExpired
		}
		controller.mu.Lock()
		if controller.session != session || !controller.running || time.Since(controller.lastSwitch) < discordRealtimeSwitchCooldown {
			controller.mu.Unlock()
			return nil
		}
		if controller.fallbackVPN {
			controller.lastSwitch = time.Now()
			initialBusy = controller.initialBusy
			controller.mu.Unlock()
			action = discordFailureRotateVPN
			return nil
		}
		if !controller.automatic {
			controller.initialBusy = false
			controller.initialReady = true
			controller.initialIdle = time.Time{}
			controller.mu.Unlock()
			action = discordFailureManual
			return nil
		}
		controller.lastSwitch = time.Now()
		controller.mu.Unlock()
		a.removeServiceStrategyCacheEntry("discord")
		action = discordFailureRotateLocal
		return nil
	}); err != nil {
		return
	}
	switch action {
	case discordFailureManual:
		a.commitDiscordRealtimeSessionAction(session, func() {
			a.endBusy(discordRealtimeBusyID)
			a.writeLog("[DiscordRealtime] failure detected but automatic routing is disabled: " + reason)
		})
		return
	case discordFailureRotateVPN:
		if initialBusy {
			a.commitDiscordRealtimeSessionAction(session, func() {
				a.updateBusy(discordRealtimeBusyID, "Проверяем Discord voice через VPN...")
			})
		}
		a.rotateDiscordVPNSource(session, reason)
		return
	case discordFailureRotateLocal:
	default:
		return
	}
	a.emitDiscordRealtimeService(session, false, false, true, reason)
	if a.rotateDiscordLocalStrategy(session, reason) {
		return
	}
	a.activateDiscordRealtimeFallback(session, reason)
}

func discordLocalStrategyCount() int {
	if count := len(nativeStrategyIDsForService("discord")); count > 0 {
		if count > discordRealtimeMaxLocalAttempts {
			return discordRealtimeMaxLocalAttempts
		}
		return count
	}
	return 1
}

func (a *App) seedDiscordRealtimeStrategyAttempts(ladder []ServiceBypassMethod, currentIndex int) {
	controller := a.discordRealtime
	if controller == nil {
		return
	}
	controller.mu.Lock()
	defer controller.mu.Unlock()
	if controller.localTried == nil {
		controller.localTried = make(map[string]bool)
	}
	for index := 0; index < currentIndex && index < len(ladder); index++ {
		if strategyID := strings.TrimSpace(ladder[index].NativeStrategyID); strategyID != "" {
			controller.localTried[strategyID] = true
		}
	}
	controller.attempt = currentIndex + 1
	if controller.attempt < 1 {
		controller.attempt = 1
	}
	if maximum := discordLocalStrategyCount(); controller.attempt > maximum {
		controller.attempt = maximum
	}
}

func (a *App) rotateDiscordLocalStrategy(session uint64, reason string) bool {
	if a == nil || a.trafficEngine == nil || !a.discordRealtimeSessionActive(a.discordRealtime, session) {
		return false
	}
	if !a.tryBeginRouteProbeDiscovery() {
		a.scheduleDiscordRealtimeFailureRetry(session, reason)
		return true
	}
	defer a.finishRouteProbeDiscovery()
	for {
		controller := a.discordRealtime
		current := ""
		next := ""
		candidateCount := 0
		initialBusy := false
		noCandidate := false
		var startErr error
		if err := a.commitRouteStrategySession(session, func() error {
			if !controller.ownsSession(session) {
				return errRouteStrategySessionExpired
			}
			a.serviceEngineComposeMu.Lock()
			defer a.serviceEngineComposeMu.Unlock()

			plan := a.trafficEngine.CurrentPlan()
			candidates := []string(nil)
			for _, service := range plan.Services {
				if service.ID == "discord" {
					candidates = append(candidates, service.CandidateStrategyIDs...)
					break
				}
			}
			for _, selection := range plan.Selections {
				if selection.ServiceID == "discord" {
					current = selection.StrategyID
					break
				}
			}
			if current == "" || len(candidates) == 0 {
				noCandidate = true
				return nil
			}
			if len(candidates) > discordRealtimeMaxLocalAttempts {
				candidates = candidates[:discordRealtimeMaxLocalAttempts]
			}
			candidateCount = len(candidates)

			controller.mu.Lock()
			if controller.session != session || !controller.running {
				controller.mu.Unlock()
				return errRouteStrategySessionExpired
			}
			if controller.localTried == nil {
				controller.localTried = make(map[string]bool)
			}
			controller.localTried[current] = true
			for _, candidate := range candidates {
				if candidate != current && !controller.localTried[candidate] {
					next = candidate
					break
				}
			}
			if next == "" {
				controller.attempt = len(candidates)
				controller.mu.Unlock()
				noCandidate = true
				return nil
			}
			controller.attempt = len(controller.localTried) + 1
			if controller.attempt > len(candidates) {
				controller.attempt = len(candidates)
			}
			initialBusy = controller.initialBusy
			controller.resetRouteObservationLocked()
			controller.mu.Unlock()

			trial := cloneTrafficPlan(plan)
			trial.Revision++
			for index := range trial.Selections {
				if trial.Selections[index].ServiceID == "discord" {
					trial.Selections[index].StrategyID = next
					break
				}
			}
			startErr = a.trafficEngine.StartPlan(trial)
			if startErr != nil {
				controller.mu.Lock()
				controller.localTried[next] = true
				controller.mu.Unlock()
			}
			return nil
		}); err != nil {
			return false
		}
		if noCandidate {
			return false
		}
		if startErr != nil {
			a.writeLog(fmt.Sprintf("[DiscordRealtime] cannot activate local strategy %s after %s: %v", next, reason, startErr))
			continue
		}
		routeSwitched, err := a.commitRouteStrategyBool(session, func() bool {
			return controller.ownsSession(session) && a.switchServiceRoute("discord", "direct")
		})
		if err != nil || !routeSwitched {
			return false
		}
		if a.probeServicesThroughEngineForSession([]string{"discord"}, session)["discord"] {
			if !a.discordRealtimeSessionActive(controller, session) {
				return false
			}
			a.writeLog(fmt.Sprintf("[DiscordRealtime] local strategy %s failed the complete Discord web/API precheck", next))
			controller.mu.Lock()
			if controller.session == session {
				controller.localTried[next] = true
			}
			controller.mu.Unlock()
			continue
		}
		if !a.discordRealtimeSessionActive(controller, session) {
			return false
		}
		if initialBusy {
			a.commitDiscordRealtimeSessionAction(session, func() {
				a.updateBusy(discordRealtimeBusyID, fmt.Sprintf("Проверяем Discord voice, локальная стратегия %d/%d...", controller.currentAttempt(), candidateCount))
			})
		}
		a.emitDiscordRealtimeCandidate(session, fmt.Sprintf("Проверяем следующую стратегию после сбоя: %s", reason))
		a.writeLog(fmt.Sprintf("[DiscordRealtime] voice failure (%s); atomically switched the complete Discord policy %s -> %s; web/API passed, waiting for live media proof", reason, current, next))
		a.closeDiscordRealtimeConnections(session)
		return true
	}
}

func (a *App) scheduleDiscordRealtimeFailureRetry(session uint64, reason string) {
	go func() {
		if !a.waitForRouteProbeDiscoverySession(session, 30*time.Second) {
			return
		}
		timer := time.NewTimer(discordRealtimeSwitchCooldown)
		defer timer.Stop()
		<-timer.C
		if a.discordRealtimeSessionActive(a.discordRealtime, session) {
			a.handleDiscordRealtimeFailure(session, reason)
		}
	}()
}

func (a *App) commitDiscordRealtimeHealthyStrategy(session uint64) {
	if a == nil || a.discordRealtime == nil {
		return
	}
	controller := a.discordRealtime
	cached := false
	if err := a.commitRouteStrategySession(session, func() error {
		if !controller.ownsSession(session) {
			return errRouteStrategySessionExpired
		}
		controller.mu.Lock()
		usingVPN := controller.fallbackVPN
		controller.mu.Unlock()
		if usingVPN {
			a.cacheServiceMethod("discord", FreeAccessMethodVPN, "discord-live-media")
			cached = true
			return nil
		}
		if a.trafficEngine == nil {
			return nil
		}
		plan := a.trafficEngine.CurrentPlan()
		selected := ""
		for _, selection := range plan.Selections {
			if selection.ServiceID == "discord" {
				selected = selection.StrategyID
				break
			}
		}
		for _, method := range rankedMethodsForService("discord") {
			if method.NativeStrategyID == selected {
				a.cacheServiceMethod("discord", method.Tag, "discord-live-media")
				cached = true
				break
			}
		}
		return nil
	}); err != nil || !cached {
		return
	}
	a.emitDiscordRealtimeService(session, true, true, false, "Discord voice подтверждён реальным двусторонним медиапотоком")
}

func (a *App) activateDiscordRealtimeFallback(session uint64, reason string) {
	controller := a.discordRealtime
	if !a.discordRealtimeSessionActive(controller, session) {
		return
	}
	controller.mu.Lock()
	if controller.session != session {
		controller.mu.Unlock()
		return
	}
	allowVPNFallback := controller.vpnFallbackAllowed
	controller.mu.Unlock()
	nextStrategyIndex := a.nextDiscordStrategyIndex()
	if allowVPNFallback && a.discordHasVPNFallback() {
		initialBusy := false
		serviceSwitched := false
		realtimeSwitched := false
		err := a.commitRouteStrategySession(session, func() error {
			if !controller.ownsSession(session) {
				return errRouteStrategySessionExpired
			}
			controller.mu.Lock()
			controller.fallbackVPN = true
			controller.vpnTried = make(map[string]bool)
			controller.resetRouteObservationLocked()
			initialBusy = controller.initialBusy
			controller.mu.Unlock()
			serviceSwitched = a.switchServiceRoute("discord", "auto-select")
			realtimeSwitched = a.switchOutboundSelector(discordRealtimeGroupTag, discordVPNGroupTag)
			if serviceSwitched && realtimeSwitched {
				controller.mu.Lock()
				if controller.session == session {
					controller.initialBusy = false
				}
				controller.mu.Unlock()
				a.cacheServiceMethodWithNextStrategy("discord", FreeAccessMethodVPN, "discord-local-batch-fallback", nextStrategyIndex)
			}
			return nil
		})
		if err != nil {
			return
		}
		if serviceSwitched && realtimeSwitched {
			a.commitDiscordRealtimeSessionAction(session, func() { a.endBusy(discordRealtimeBusyID) })
			if initialBusy {
				a.writeLog("[DiscordRealtime] local verification window completed; Discord will reconnect through the VPN subscription")
			}
			a.writeLog(fmt.Sprintf("[DiscordRealtime] all %d local attempts failed; switched the complete Discord policy to VPN: %s", discordLocalStrategyCount(), reason))
			a.emitDiscordRealtimeCandidate(session, "Локальные стратегии не сработали; проверяем Discord voice через VPN-подписку")
			a.closeDiscordRealtimeConnections(session)
			return
		}
	}
	if err := a.commitRouteStrategySession(session, func() error {
		if !controller.ownsSession(session) {
			return errRouteStrategySessionExpired
		}
		a.switchServiceRoute("discord", "direct")
		a.switchOutboundSelector(discordRealtimeGroupTag, "direct")
		controller.mu.Lock()
		controller.fallbackVPN = false
		controller.initialBusy = false
		controller.initialReady = true
		controller.initialIdle = time.Time{}
		controller.automatic = false
		controller.mu.Unlock()
		a.cacheServiceMethodWithNextStrategy("discord", FreeAccessMethodDirect, "discord-live-media-fallback", nextStrategyIndex)
		return nil
	}); err != nil {
		return
	}
	a.commitDiscordRealtimeSessionAction(session, func() { a.endBusy(discordRealtimeBusyID) })
	a.emitDiscordRealtimeService(session, false, true, false, "В этой сессии проверены 4 стратегии Discord voice; следующий запуск продолжит со следующего набора")
	a.writeLog(fmt.Sprintf("[DiscordRealtime] all %d local attempts failed; direct fallback selected for this session and the next strategy cursor was saved", discordLocalStrategyCount()))
}

func (a *App) nextDiscordStrategyIndex() int {
	if a == nil || a.trafficEngine == nil {
		return 0
	}
	selectedID := ""
	for _, selection := range a.trafficEngine.CurrentPlan().Selections {
		if selection.ServiceID == "discord" {
			selectedID = selection.StrategyID
			break
		}
	}
	return nextServiceStrategyIndexAfterAttemptWindow("discord", selectedID, 1)
}

func (a *App) discordRealtimeProgressSnapshot() (methodTag, methodLabel string, attempt, attemptTotal, strategyIndex, strategyTotal, cycle, cycleTotal int) {
	strategyTotal = discordLocalStrategyCount()
	cycleTotal = 1
	strategyIndex = 1
	cycle = 1
	usingVPN := false
	if controller := a.discordRealtime; controller != nil {
		controller.mu.Lock()
		strategyIndex = controller.attempt
		usingVPN = controller.fallbackVPN
		controller.mu.Unlock()
	}
	if strategyIndex < 1 {
		strategyIndex = 1
	}
	if strategyIndex > strategyTotal {
		strategyIndex = strategyTotal
	}
	if cycle < 1 {
		cycle = 1
	}
	if usingVPN {
		methodTag = FreeAccessMethodVPN
		methodLabel = FreeAccessOutboundLabel(FreeAccessMethodVPN)
	} else if a.trafficEngine != nil {
		selectedID := ""
		for _, selection := range a.trafficEngine.CurrentPlan().Selections {
			if selection.ServiceID == "discord" {
				selectedID = selection.StrategyID
				break
			}
		}
		for _, method := range rankedMethodsForService("discord") {
			if method.NativeStrategyID == selectedID {
				methodTag = method.Tag
				methodLabel = method.Label
				break
			}
		}
	}
	if methodLabel == "" {
		methodLabel = "Локальная стратегия Discord"
	}
	attempt = (cycle-1)*strategyTotal + strategyIndex
	attemptTotal = cycleTotal * strategyTotal
	return
}

func (a *App) emitDiscordRealtimeCandidate(session uint64, detail string) {
	a.commitDiscordRealtimeSessionAction(session, func() {
		methodTag, methodLabel, attempt, attemptTotal, strategyIndex, strategyTotal, cycle, cycleTotal := a.discordRealtimeProgressSnapshot()
		a.emitRouteProbe("route-probe-candidate", map[string]interface{}{
			"source":        backgroundServiceStrategySource,
			"serviceTag":    "discord",
			"serviceName":   serviceDisplayNameForTag("discord"),
			"methodTag":     methodTag,
			"methodLabel":   methodLabel,
			"status":        "voice-check",
			"error":         detail,
			"attempt":       attempt,
			"attemptTotal":  attemptTotal,
			"strategyIndex": strategyIndex,
			"strategyTotal": strategyTotal,
			"cycle":         cycle,
			"cycleTotal":    cycleTotal,
		})
	})
}

func (a *App) emitDiscordRealtimeService(session uint64, success, final, retrying bool, detail string) {
	a.commitDiscordRealtimeSessionAction(session, func() {
		methodTag, methodLabel, attempt, attemptTotal, strategyIndex, strategyTotal, cycle, cycleTotal := a.discordRealtimeProgressSnapshot()
		status := "retrying"
		if success {
			status = "done"
		} else if final {
			status = "failed"
		}
		a.emitRouteProbe("route-probe-service", map[string]interface{}{
			"source":        backgroundServiceStrategySource,
			"tag":           "discord",
			"name":          serviceDisplayNameForTag("discord"),
			"methodTag":     methodTag,
			"methodLabel":   methodLabel,
			"success":       success,
			"final":         final,
			"retrying":      retrying,
			"status":        status,
			"error":         detail,
			"attempt":       attempt,
			"attemptTotal":  attemptTotal,
			"strategyIndex": strategyIndex,
			"strategyTotal": strategyTotal,
			"cycle":         cycle,
			"cycleTotal":    cycleTotal,
		})
	})
}

func (a *App) discordHasVPNFallback() bool {
	if a.storage == nil {
		return false
	}
	config, err := readJSONConfig(a.storage.ActiveConfigFilePath())
	if err != nil {
		return false
	}
	outbounds, ok := config["outbounds"].([]interface{})
	return ok && outboundTagExists(outbounds, discordVPNGroupTag)
}

func (a *App) closeClashConnection(id string) error {
	if strings.TrimSpace(id) == "" {
		return fmt.Errorf("connection id is empty")
	}
	client := &http.Client{Timeout: 2 * time.Second}
	req, err := a.newClashAPIRequest(http.MethodDelete, "/connections/"+id, nil)
	if err != nil {
		return err
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return nil
}

func (a *App) closeDiscordRealtimeConnections(session uint64) {
	if !a.discordRealtimeSessionActive(a.discordRealtime, session) {
		return
	}
	document, err := a.fetchClashConnections()
	if !a.discordRealtimeSessionActive(a.discordRealtime, session) {
		return
	}
	if err != nil {
		a.writeLog(fmt.Sprintf("[DiscordRealtime][Reconnect] cannot enumerate connections: %v", err))
		return
	}
	attempted := 0
	closed := 0
	for _, connection := range document.Connections {
		if !isDiscordConnection(connection) {
			continue
		}
		network := strings.ToLower(strings.TrimSpace(connection.Metadata.Network))
		if network == "udp" || isDiscordVoiceGateway(connection, normalizeDiscordHost(connection.Metadata.Host), clashPort(connection.Metadata.DestinationPort)) {
			attempted++
			port := clashPort(connection.Metadata.DestinationPort)
			destination := net.JoinHostPort(connection.Metadata.DestinationIP, strconv.Itoa(port))
			err := a.commitRouteStrategySession(session, func() error {
				if !a.discordRealtime.ownsSession(session) {
					return errRouteStrategySessionExpired
				}
				return a.closeClashConnection(connection.ID)
			})
			if err != nil {
				if !a.discordRealtimeSessionActive(a.discordRealtime, session) {
					return
				}
				a.writeLog(fmt.Sprintf("[DiscordRealtime][Reconnect] close failed id=%s network=%s destination=%s chains=%s: %v", connection.ID, network, destination, strings.Join(connection.Chains, " -> "), err))
				continue
			}
			closed++
			a.writeLog(fmt.Sprintf("[DiscordRealtime][Reconnect] closed id=%s network=%s destination=%s chains=%s", connection.ID, network, destination, strings.Join(connection.Chains, " -> ")))
		}
	}
	a.writeLog(fmt.Sprintf("[DiscordRealtime][Reconnect] completed: eligible=%d closed=%d failed=%d", attempted, closed, attempted-closed))
}

func (a *App) rotateDiscordVPNSource(session uint64, reason string) {
	controller := a.discordRealtime
	if !a.discordRealtimeSessionActive(controller, session) {
		return
	}
	candidates, current := a.selectorCandidates(discordVPNGroupTag)
	if !a.discordRealtimeSessionActive(controller, session) {
		return
	}
	if len(candidates) == 0 {
		if err := a.commitRouteStrategySession(session, func() error {
			if !controller.ownsSession(session) {
				return errRouteStrategySessionExpired
			}
			a.switchServiceRoute("discord", "direct")
			a.switchOutboundSelector(discordRealtimeGroupTag, "direct")
			controller.mu.Lock()
			controller.initialBusy = false
			controller.initialReady = true
			controller.initialIdle = time.Time{}
			controller.fallbackVPN = false
			controller.automatic = false
			controller.mu.Unlock()
			return nil
		}); err != nil {
			return
		}
		a.commitDiscordRealtimeSessionAction(session, func() { a.endBusy(discordRealtimeBusyID) })
		a.writeLog("[DiscordRealtime] VPN UDP failed and no alternative VPN source exists; switched to direct")
		a.closeDiscordRealtimeConnections(session)
		return
	}
	controller.mu.Lock()
	if controller.session != session || !controller.running {
		controller.mu.Unlock()
		return
	}
	if controller.vpnTried == nil {
		controller.vpnTried = make(map[string]bool)
	}
	if current != "" {
		controller.vpnTried[current] = true
	}
	next := ""
	for _, candidate := range candidates {
		if candidate != current && !controller.vpnTried[candidate] {
			next = candidate
			break
		}
	}
	controller.mu.Unlock()
	switched := false
	initialBusy := false
	if next != "" {
		var err error
		switched, err = a.commitRouteStrategyBool(session, func() bool {
			if !controller.ownsSession(session) || !a.switchOutboundSelector(discordVPNGroupTag, next) {
				return false
			}
			controller.mu.Lock()
			initialBusy = controller.initialBusy
			controller.resetRouteObservationLocked()
			controller.mu.Unlock()
			return true
		})
		if err != nil {
			return
		}
	}
	if next == "" || !switched {
		if err := a.commitRouteStrategySession(session, func() error {
			if !controller.ownsSession(session) {
				return errRouteStrategySessionExpired
			}
			a.switchServiceRoute("discord", "direct")
			a.switchOutboundSelector(discordRealtimeGroupTag, "direct")
			controller.mu.Lock()
			controller.fallbackVPN = false
			controller.vpnTried = make(map[string]bool)
			controller.resetRouteObservationLocked()
			controller.mu.Unlock()
			return nil
		}); err != nil {
			return
		}
		a.writeLog(fmt.Sprintf("[DiscordRealtime] every independent VPN source failed the current realtime health window (%s); switched to direct but kept automatic recovery enabled", reason))
		a.closeDiscordRealtimeConnections(session)
		return
	}
	a.writeLog(fmt.Sprintf("[DiscordRealtime] VPN realtime failure (%s); switched fallback source %s -> %s", reason, current, next))
	if initialBusy {
		a.commitDiscordRealtimeSessionAction(session, func() {
			a.updateBusy(discordRealtimeBusyID, fmt.Sprintf("Проверяем следующий VPN-источник для Discord voice: %s", next))
		})
	}
	a.closeDiscordRealtimeConnections(session)
}

func (a *App) selectorCandidates(groupTag string) ([]string, string) {
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := a.clashAPIGet(client, clashProxyAPIPath(groupTag))
	if err != nil {
		return nil, ""
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, ""
	}
	body, err := readHTTPBodyLimited(resp.Body, defaultMaxHTTPResponseBytes)
	if err != nil {
		return nil, ""
	}
	var selector struct {
		All []string `json:"all"`
		Now string   `json:"now"`
	}
	if json.Unmarshal(body, &selector) != nil {
		return nil, ""
	}
	return selector.All, selector.Now
}
