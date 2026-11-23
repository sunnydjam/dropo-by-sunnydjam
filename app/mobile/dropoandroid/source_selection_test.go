package dropoandroid

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	M "github.com/sagernet/sing/common/metadata"
)

type testOutboundDialer struct {
	address string
	calls   atomic.Int32
}

func (d *testOutboundDialer) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	d.calls.Add(1)
	return (&net.Dialer{}).DialContext(ctx, network, d.address)
}
func (*testOutboundDialer) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return nil, errors.New("not used")
}

func TestSourceChoiceUsesIndependentSourcesAndStablePriority(t *testing.T) {
	candidates := []sourceCandidate{{ID: "first", NodeID: "a"}, {ID: "second", NodeID: "b"}, {ID: "third", NodeID: "c"}}
	results := []sourceObservation{{SourceID: "first", NodeID: "a", State: "failed"},
		{SourceID: "second", NodeID: "b", State: "ok", LatencyMS: 80}, {SourceID: "third", NodeID: "c", State: "ok", LatencyMS: 30},
		{SourceID: "first", NodeID: "sibling", State: "ok", LatencyMS: 1}}
	if actual := chooseSourceCandidate(candidates, results, true); actual != "third" {
		t.Fatalf("automatic chose %q", actual)
	}
	if actual := chooseSourceCandidate(candidates, results, false); actual != "second" {
		t.Fatalf("ordered fallback chose %q", actual)
	}
	results[1].State, results[2].State = "failed", "failed"
	if actual := chooseSourceCandidate(candidates, results, true); actual != "" {
		t.Fatalf("partial health or sibling selected %q", actual)
	}
}

func TestManagedSourceSelectionKeepsReservesWithinTheActiveProfile(t *testing.T) {
	free := sourceCandidate{ID: "free", NodeID: "a"}
	turbo := sourceCandidate{ID: "turbo", NodeID: "b"}
	turboReserve := sourceCandidate{ID: "turbo-reserve", NodeID: "c", OwnerID: "turbo"}
	personal := sourceCandidate{ID: "personal", NodeID: "d"}
	candidates := []sourceCandidate{free, turbo, turboReserve, personal}
	results := []sourceObservation{
		{SourceID: free.ID, NodeID: free.NodeID, State: "ok", LatencyMS: 30},
		{SourceID: turbo.ID, NodeID: turbo.NodeID, State: "ok", LatencyMS: 70},
		{SourceID: turboReserve.ID, NodeID: turboReserve.NodeID, State: "ok", LatencyMS: 10},
		{SourceID: personal.ID, NodeID: personal.NodeID, State: "ok", LatencyMS: 40},
	}
	if chosen := chooseSourceCandidate(candidates, results, true); chosen != free.ID {
		t.Fatalf("automatic selection preferred a reserve over its healthy primary: %q", chosen)
	}
	results[1].State = "failed"
	if chosen := chooseSourceAfterOutage(turbo, candidates, results); chosen != turboReserve.ID {
		t.Fatalf("Turbo outage selected a different profile before its own reserve: %q", chosen)
	}
	results[2].State, results[0].State = "failed", "failed"
	if chosen := chooseSourceAfterOutage(turbo, candidates, results); chosen != personal.ID {
		t.Fatalf("personal subscription did not remain an independent fallback: %q", chosen)
	}
}

func TestSourceHTTPUsesExplicitOutboundAndRequiresExact204(t *testing.T) {
	for _, status := range []int{204, 200, 302, 503} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodHead {
					t.Error("probe is not HEAD")
				}
				w.WriteHeader(status)
			}))
			defer server.Close()
			dialer := &testOutboundDialer{address: server.Listener.Addr().String()}
			err := probeSourceHTTP(context.Background(), "http://probe.invalid/generate_204", dialer)
			if (err == nil) != (status == 204) {
				t.Fatalf("HTTP %d result: %v", status, err)
			}
			if dialer.calls.Load() != 1 {
				t.Fatal("probe bypassed explicit source or followed a redirect")
			}
		})
	}
}

func TestFirstVerifiedEndpointDoesNotWaitForSlowPeer(t *testing.T) {
	started, stopped := make(chan struct{}), make(chan struct{})
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	latency, ok := firstVerifiedEndpoint(ctx, []string{"slow", "fast"}, func(ctx context.Context, target string) error {
		if target == "slow" {
			close(started)
			<-ctx.Done()
			close(stopped)
			return ctx.Err()
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-started:
			return nil
		}
	})
	if !ok || latency < 1 {
		t.Fatal("healthy peer was not accepted")
	}
	select {
	case <-stopped:
	case <-ctx.Done():
		t.Fatal("losing request was not cancelled")
	}
}

func TestFirstVerifiedEndpointRejectsFailuresAndCancelledSession(t *testing.T) {
	var calls atomic.Int32
	probe := func(context.Context, string) error { calls.Add(1); return errors.New("unavailable") }
	if _, ok := firstVerifiedEndpoint(context.Background(), []string{"one", "two"}, probe); ok || calls.Load() != 2 {
		t.Fatal("both failures must reject the candidate")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, ok := firstVerifiedEndpoint(ctx, []string{"one", "two"}, func(context.Context, string) error { return nil }); ok {
		t.Fatal("cancelled session accepted a response")
	}
}

func TestSourceHTTPStopCancelsInflightRequest(t *testing.T) {
	entered := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(entered)
		<-r.Context().Done()
	}))
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- probeSourceHTTP(ctx, "http://probe.invalid/generate_204", &testOutboundDialer{address: server.Listener.Addr().String()})
	}()
	<-entered
	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancelled HTTP check succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("Stop did not interrupt HTTP check")
	}
}

func TestSourceBatchIsBoundedAndCancellable(t *testing.T) {
	candidates := make([]sourceCandidate, 16)
	var running, peak atomic.Int32
	ctx, cancel := context.WithCancel(context.Background())
	entered := make(chan struct{}, 16)
	done := make(chan struct{})
	go func() {
		probeSourceCandidates(ctx, candidates, func(ctx context.Context, candidate sourceCandidate) sourceObservation {
			count := running.Add(1)
			for {
				old := peak.Load()
				if old >= count || peak.CompareAndSwap(old, count) {
					break
				}
			}
			entered <- struct{}{}
			<-ctx.Done()
			running.Add(-1)
			return sourceObservation{}
		})
		close(done)
	}()
	for range 4 {
		<-entered
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("batch did not cancel")
	}
	if peak.Load() > 4 || running.Load() != 0 {
		t.Fatalf("unbounded probe work: peak=%d running=%d", peak.Load(), running.Load())
	}
}

func TestPhysicalNetworkChangeCancelsAndFencesOldProbeCycle(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	server := &CommandServer{sourceCancel: cancel, sourceGeneration: 3, sourceWake: make(chan struct{}, 1)}
	cycle, finish := server.beginSourceCycle(ctx, 3)
	defer finish()
	server.RecheckSourceSelection()
	if cycle.Err() == nil {
		t.Fatal("physical handover did not cancel old network's HTTP checks")
	}
	if server.commitSourceResults(cycle, 3, 0, nil, "", nil) {
		t.Fatal("old network observations committed")
	}
	select {
	case <-server.sourceWake:
	default:
		t.Fatal("new network did not wake a fresh cycle")
	}
	server.StopSourceSelection()
	server.RecheckSourceSelection()
	if server.sourceCancel != nil || server.sourceWake != nil {
		t.Fatal("network callback revived a stopped session")
	}
}

func TestAutoCachedSixthEntryStartsEarlyAndKeepsWinner(t *testing.T) {
	candidates := []sourceCandidate{{ID: "primary"}, {ID: "relay"}, {ID: "unreachable"}, {ID: "another"}, {ID: "slow"}, {ID: "last-working"}}
	hold := make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	picked := make(chan string, 6)
	done := make(chan int, 1)
	go func() {
		results := raceSourceCandidates(ctx, candidates, "last-working", func(ctx context.Context, c sourceCandidate) sourceObservation {
			if c.ID != "last-working" {
				select {
				case <-ctx.Done():
					return sourceObservation{}
				case <-hold:
				}
			}
			return sourceObservation{State: "ok", LatencyMS: 1, SourceID: c.ID}
		}, func(c sourceCandidate, _ sourceObservation) bool { picked <- c.ID; return true })
		done <- len(results)
	}()
	select {
	case id := <-picked:
		if id != "last-working" {
			t.Fatal("cache ignored")
		}
	case <-time.After(time.Second):
		t.Fatal("ready blocked on background probes")
	}
	close(hold)
	if n := <-done; n != 6 || len(picked) != 0 || candidates[0].ID != "primary" {
		t.Fatal("changed winner, priority, or skipped background entries")
	}
}

func TestManagedMethodsRankOnceThenTryTheNextInSequence(t *testing.T) {
	candidates := []sourceCandidate{
		{ID: "hy2", NodeID: "n1", OwnerID: "free"},
		{ID: "xhttp", NodeID: "n2", OwnerID: "free"},
		{ID: "tcp", NodeID: "n3", OwnerID: "free"},
	}
	result := func(c sourceCandidate, latency int) sourceObservation {
		return sourceObservation{SourceID: c.ID, NodeID: c.NodeID, State: "ok", LatencyMS: latency}
	}
	results := []sourceObservation{result(candidates[0], 45), result(candidates[1], 15), result(candidates[2], 25)}
	queue := rankManagedSourceCandidates(candidates, results, true)
	if got := chooseSourceCandidate(queue, results, false); got != "xhttp" {
		t.Fatalf("initial selection = %q", got)
	}
	var tried []string
	healthy := func(_ context.Context, c sourceCandidate) sourceObservation {
		tried = append(tried, c.ID)
		return result(c, 120)
	}
	fallback, _ := probeManagedFailover(context.Background(), queue, "xhttp", healthy)
	next, _ := probeManagedFailover(context.Background(), queue, fallback, healthy)
	if fallback != "tcp" || next != "hy2" || !slices.Equal(tried, []string{"tcp", "hy2"}) {
		t.Fatalf("failover rescored or skipped its next route: %v", tried)
	}
}
