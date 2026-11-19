package dropoandroid

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"dropocore/sourcehistory"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"slices"
	"strings"
	"sync"
	"time"

	core "dropocore"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/protocol/group"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

const sourceProbeTimeout = 6 * time.Second

var sourceProbeTargets = []string{"https://www.gstatic.com/generate_204", "https://cp.cloudflare.com/generate_204"}

type sourceCandidate struct {
	ID      string `json:"id"`
	Tag     string `json:"tag"`
	NodeID  string `json:"nodeId"`
	OwnerID string `json:"ownerId,omitempty"`
}

func (c sourceCandidate) owner() string {
	if c.OwnerID != "" {
		return c.OwnerID
	}
	return c.ID
}

type sourceObservation struct {
	State             string `json:"state"`
	LatencyMS         int    `json:"latencyMs,omitempty"`
	CheckedAt         string `json:"checkedAt"`
	SourceID          string `json:"sourceId"`
	NodeID            string `json:"nodeId"`
	Target            string `json:"target"`
	SessionGeneration int64  `json:"sessionGeneration"`
}

// StartSourceSelection returns immediately after registering a session. Only
// after Kotlin publishes Connected does this worker test independent outbounds.
func (s *CommandServer) StartSourceSelection() error {
	return s.startSourceSelection("")
}

func (s *CommandServer) startSourceSelection(activeID string) error {
	return s.launchSourceSelection(activeID, nil)
}

// StartVerifiedSourceSelection waits for the existing selector to commit a
// working outbound. The Android service worker owns the wait; Stop cancels it.
func (s *CommandServer) StartVerifiedSourceSelection() error {
	checked := make(chan bool, 1)
	if err := s.launchSourceSelection("", checked); err != nil {
		return err
	}
	timer := time.NewTimer(45 * time.Second)
	defer timer.Stop()
	select {
	case ok := <-checked:
		if ok {
			return nil
		}
	case <-timer.C:
	}
	return errors.New("Не удалось подключиться. Ни один доступный вход не подтвердил соединение.")
}

func (s *CommandServer) launchSourceSelection(activeID string, checked chan bool) error {
	s.sourceMu.Lock()
	defer s.sourceMu.Unlock()
	s.stopSourceSelectionLocked()
	instance := s.inner.StartedService.Instance()
	if instance == nil || instance.Box() == nil {
		return errors.New("VPN engine is not ready for source checks")
	}
	var plan struct {
		Success    bool              `json:"success"`
		Generation int64             `json:"generation"`
		AutoSelect bool              `json:"autoSelect"`
		Candidates []sourceCandidate `json:"candidates"`
		ActiveID   string            `json:"activeId"`
	}
	if json.Unmarshal([]byte(core.BeginAndroidSourceSessionWithActive(activeID)), &plan) != nil || !plan.Success || len(plan.Candidates) == 0 {
		return errors.New("VPN sources are not ready for source checks")
	}
	outbounds := instance.Box().Outbound()
	selected, exists := outbounds.Outbound("proxy")
	selector, valid := selected.(*group.Selector)
	selectedTag := ""
	for _, candidate := range plan.Candidates {
		if candidate.ID == plan.ActiveID {
			selectedTag = candidate.Tag
			break
		}
	}
	if !exists || !valid || selectedTag == "" || !selector.SelectOutbound(selectedTag) {
		core.EndAndroidSourceSession(plan.Generation)
		return errors.New("VPN source selector is not ready")
	}
	ctx, cancel := context.WithCancel(context.Background())
	s.sourceCancel = cancel
	s.sourceCoreGeneration = plan.Generation
	s.sourceWake = make(chan struct{}, 1)
	s.sourceGeneration++
	generation, wake := s.sourceGeneration, s.sourceWake
	s.startAdaptiveLocked(ctx, generation, plan.Generation, outbounds)
	var flows sourceFlowTable
	if manager := instance.TrafficManager(); manager != nil {
		flows = manager
	}
	fresh := activeID == "" || plan.ActiveID != activeID
	if !fresh {
		wake <- struct{}{}
	}
	go s.runSourceSelection(ctx, generation, plan.Generation, plan.AutoSelect, plan.Candidates, outbounds, selector, flows, wake, plan.ActiveID, fresh, checked)
	go core.RefreshAndroidSourcesForNextSession(ctx, plan.Generation)
	return nil
}

// StopSourceSelection is safe on the caller thread, before queued engine
// cleanup. It serializes against all selector commits and cancels every HTTP
// request. No cancelled worker can reload an engine or mutate its selector.
func (s *CommandServer) StopSourceSelection() {
	s.sourceMu.Lock()
	s.stopSourceSelectionLocked()
	s.sourceMu.Unlock()
}

func (s *CommandServer) stopSourceSelectionLocked() {
	s.sourceGeneration++
	s.resetAdaptiveLocked()
	s.adaptiveWake = nil
	s.adaptiveSelectors = nil
	if s.sourceCancel != nil {
		s.sourceCancel()
		s.sourceCancel = nil
	}
	if s.sourceCycleCancel != nil {
		s.sourceCycleCancel()
		s.sourceCycleCancel = nil
	}
	core.EndAndroidSourceSession(s.sourceCoreGeneration)
	s.sourceCoreGeneration, s.sourceWake = 0, nil
}

// A changed/lost physical network invalidates displayed observations at once
// and wakes a bounded health cycle; it does not recreate the engine or TUN.
func (s *CommandServer) SetSourceNetwork(identity string) {
	key := ""
	if identity != "" {
		key = fmt.Sprintf("%x", sha256.Sum256([]byte(identity)))
	}
	s.sourceMu.Lock()
	defer s.sourceMu.Unlock()
	if s.sourceNetwork != key && s.sourceCycleCancel != nil {
		s.sourceCycleCancel()
	}
	s.sourceNetwork = key
}

func (s *CommandServer) RecheckSourceSelection() {
	s.sourceMu.Lock()
	defer s.sourceMu.Unlock()
	if s.sourceCancel == nil || s.sourceWake == nil {
		return
	}
	if s.sourceCycleCancel != nil {
		s.sourceCycleCancel()
	}
	s.resetAdaptiveLocked()
	if s.adaptiveWake != nil {
		select {
		case s.adaptiveWake <- struct{}{}:
		default:
		}
	}
	core.InvalidateAndroidSourceObservations(s.sourceCoreGeneration)
	select {
	case s.sourceWake <- struct{}{}:
	default:
	}
}

type sourceSelector struct{ selector *group.Selector }

func (s sourceSelector) SelectSourceTag(tag string) bool { return s.selector.SelectOutbound(tag) }

func (s *CommandServer) commitSourceResults(ctx context.Context, generation uint64, coreGeneration int64, results []sourceObservation, selectedID string, selector *group.Selector) bool {
	return s.commitSourceResultsWithOutage(ctx, generation, coreGeneration, results, selectedID, selector, "", nil)
}

func (s *CommandServer) commitSourceResultsWithOutage(ctx context.Context, generation uint64, coreGeneration int64, results []sourceObservation, selectedID string, selector *group.Selector, failedTag string, flows sourceFlowTable) bool {
	s.sourceMu.Lock()
	defer s.sourceMu.Unlock()
	if ctx.Err() != nil || s.sourceGeneration != generation {
		return false
	}
	encoded, err := json.Marshal(results)
	if err != nil {
		return false
	}
	// Keep the old instance and source generation fenced through cleanup. Stop,
	// reload and physical-network rechecks cannot transfer this work to a new
	// session; core cancellation is checked again before each individual close.
	current := func() bool {
		return ctx.Err() == nil && s.sourceGeneration == generation && core.AndroidSourceSessionCurrent(coreGeneration)
	}
	ok := commitSourceAndCleanup(current, func() bool {
		return core.CommitAndroidSourceProbeBatch(coreGeneration, string(encoded), selectedID, sourceSelector{selector})
	}, flows, failedTag)
	if ok && selectedID != "" {
		core.RememberAndroidNetworkSource(s.sourceNetwork, coreGeneration)
	}
	return ok
}

func (s *CommandServer) runSourceSelection(ctx context.Context, generation uint64, coreGeneration int64, automatic bool, candidates []sourceCandidate, outbounds adapter.OutboundManager, selector *group.Selector, flows sourceFlowTable, wake <-chan struct{}, activeID string, initial bool, checked chan bool) {
	defer func() {
		if checked != nil {
			close(checked)
		}
	}()
	probe := func(ctx context.Context, candidate sourceCandidate) sourceObservation {
		outbound, ok := outbounds.Outbound(candidate.Tag)
		if !ok {
			return failedSourceObservation(candidate, coreGeneration)
		}
		return probeSource(ctx, candidate, coreGeneration, outbound)
	}
	s.sourceMu.Lock()
	lastNetwork := s.sourceNetwork
	s.sourceMu.Unlock()
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		if !initial {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			case <-wake:
				s.sourceMu.Lock()
				changed := lastNetwork != s.sourceNetwork
				s.sourceMu.Unlock()
				if automatic && changed {
					initial = true
				}
			}
		}
		if !core.AndroidSourceSessionCurrent(coreGeneration) {
			return
		}
		cycleCtx, cancel := s.beginSourceCycle(ctx, generation)
		var results []sourceObservation
		var confirmedFailed sourceCandidate
		chosen := ""
		if initial && automatic {
			s.sourceMu.Lock()
			network := s.sourceNetwork
			lastNetwork = network
			s.sourceMu.Unlock()
			preferred := core.PreferredAndroidNetworkSource(network, coreGeneration)
			results = raceSourceCandidates(cycleCtx, candidates, preferred, probe, func(c sourceCandidate, r sourceObservation) bool {
				if !s.commitSourceResults(cycleCtx, generation, coreGeneration, []sourceObservation{r}, c.ID, selector) {
					return false
				}
				activeID = c.ID
				if checked != nil {
					checked <- true
					checked = nil
				}
				return true
			})
			// Publish the rest as observations only. An active healthy flow stays put.
		} else if initial {
			results = probeSourceCandidates(cycleCtx, candidates, probe)
			chosen = chooseSourceCandidate(candidates, results, automatic)
		} else {
			var active sourceCandidate
			for _, candidate := range candidates {
				if candidate.ID == activeID {
					active = candidate
					break
				}
			}
			result := probe(cycleCtx, active)
			if result.State != "ok" && cycleCtx.Err() == nil {
				// Confirm failure before moving an established connection.
				result = probe(cycleCtx, active)
			}
			results = []sourceObservation{result}
			if result.State != "ok" && cycleCtx.Err() == nil {
				confirmedFailed = active
				results = probeSourceCandidates(cycleCtx, candidates, probe)
				chosen = chooseSourceAfterOutage(active, candidates, results)
			}
		}
		if cycleCtx.Err() != nil {
			cancel()
			if ctx.Err() != nil {
				return
			}
			continue
		}
		failedTag := confirmedOutageSourceTag(confirmedFailed, candidates, results, chosen)
		committed := s.commitSourceResultsWithOutage(cycleCtx, generation, coreGeneration, results, chosen, selector, failedTag, flows)
		cancel()
		if !committed {
			if ctx.Err() != nil || !core.AndroidSourceSessionCurrent(coreGeneration) {
				return
			}
			continue
		}
		if checked != nil {
			checked <- chosen != ""
			checked = nil
		}
		initial = false
		if chosen != "" {
			activeID = chosen
		}
	}
}

func (s *CommandServer) beginSourceCycle(ctx context.Context, generation uint64) (context.Context, context.CancelFunc) {
	s.sourceMu.Lock()
	defer s.sourceMu.Unlock()
	cycleCtx, cancel := context.WithCancel(ctx)
	if generation != s.sourceGeneration || ctx.Err() != nil {
		cancel()
		return cycleCtx, cancel
	}
	if s.sourceCycleCancel != nil {
		s.sourceCycleCancel()
	}
	s.sourceCycleCancel = cancel
	return cycleCtx, cancel
}

func failedSourceObservation(candidate sourceCandidate, generation int64) sourceObservation {
	return sourceObservation{State: "failed", CheckedAt: time.Now().UTC().Format(time.RFC3339Nano),
		SourceID: candidate.ID, NodeID: candidate.NodeID, SessionGeneration: generation,
		Target: strings.Join(sourceProbeTargets, ", ")}
}

// Bounded concurrency retains the original source order in results. A source
// is healthy only after BOTH independent HTTPS endpoints return exact 204s.
func probeSourceCandidates(ctx context.Context, candidates []sourceCandidate, probe func(context.Context, sourceCandidate) sourceObservation) []sourceObservation {
	results := make([]sourceObservation, len(candidates))
	var workers sync.WaitGroup
	limit := make(chan struct{}, 4)
	for i, candidate := range candidates {
		select {
		case <-ctx.Done():
			workers.Wait()
			return results
		case limit <- struct{}{}:
		}
		workers.Add(1)
		go func(i int, candidate sourceCandidate) {
			defer workers.Done()
			defer func() { <-limit }()
			results[i] = probe(ctx, candidate)
		}(i, candidate)
	}
	workers.Wait()
	return results
}

func raceSourceCandidates(ctx context.Context, candidates []sourceCandidate, preferred string, probe func(context.Context, sourceCandidate) sourceObservation, choose func(sourceCandidate, sourceObservation) bool) []sourceObservation {
	ordered := slices.Clone(candidates)
	for i, c := range ordered {
		if c.ID == preferred {
			copy(ordered[1:i+1], ordered[:i])
			ordered[0] = c
			break
		}
	}
	results := make([]sourceObservation, 0, len(ordered))
	selected := false
	sourcehistory.Race(ctx, ordered, 4, probe, func(c sourceCandidate, r sourceObservation) {
		results = append(results, r)
		if !selected && r.State == "ok" && r.LatencyMS > 0 {
			selected = choose(c, r)
		}
	})
	return results
}

func chooseSourceCandidate(candidates []sourceCandidate, results []sourceObservation, automatic bool) string {
	bestID, bestLatency := "", 0
	healthyOwners := make(map[string]bool, len(candidates))
	for _, candidate := range candidates {
		if healthyOwners[candidate.owner()] {
			continue
		}
		for _, result := range results {
			if result.SourceID != candidate.ID || result.NodeID != candidate.NodeID || result.State != "ok" || result.LatencyMS < 1 {
				continue
			}
			if bestID == "" || automatic && result.LatencyMS < bestLatency {
				bestID, bestLatency = candidate.ID, result.LatencyMS
			}
			if !automatic {
				return bestID
			}
			healthyOwners[candidate.owner()] = true
			break
		}
	}
	return bestID
}

func chooseSourceAfterOutage(active sourceCandidate, candidates []sourceCandidate, results []sourceObservation) string {
	for _, result := range results {
		if result.SourceID == active.ID && result.NodeID == active.NodeID && result.State == "ok" && result.LatencyMS > 0 {
			return active.ID
		}
	}
	var sameOwner []sourceCandidate
	for _, candidate := range candidates {
		if candidate.owner() == active.owner() {
			sameOwner = append(sameOwner, candidate)
		}
	}
	if chosen := chooseSourceCandidate(sameOwner, results, false); chosen != "" {
		return chosen
	}
	return chooseSourceCandidate(candidates, results, false)
}

func probeSource(ctx context.Context, candidate sourceCandidate, generation int64, outbound N.Dialer) sourceObservation {
	result := failedSourceObservation(candidate, generation)
	total := 0
	for _, target := range sourceProbeTargets {
		probeCtx, cancel := context.WithTimeout(ctx, sourceProbeTimeout)
		started := time.Now()
		err := probeSourceHTTP(probeCtx, target, outbound)
		elapsed := int(time.Since(started).Milliseconds())
		cancel()
		if err != nil {
			return result
		}
		if elapsed < 1 {
			elapsed = 1
		}
		total += elapsed
	}
	result.State, result.LatencyMS = "ok", total/len(sourceProbeTargets)
	result.CheckedAt = time.Now().UTC().Format(time.RFC3339Nano)
	return result
}

func probeSourceHTTP(ctx context.Context, target string, outbound N.Dialer) error {
	transport := &http.Transport{Proxy: nil, DisableKeepAlives: true,
		TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12},
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			return outbound.DialContext(ctx, N.NetworkTCP, M.ParseSocksaddr(address))
		}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	request, err := http.NewRequestWithContext(ctx, http.MethodHead, target, nil)
	if err != nil {
		return err
	}
	request.Header.Set("User-Agent", "Dropo-Android-connectivity")
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	_, _ = io.CopyN(io.Discard, response.Body, 1024)
	if response.StatusCode != http.StatusNoContent {
		return fmt.Errorf("connectivity endpoint returned HTTP %d", response.StatusCode)
	}
	return nil
}
