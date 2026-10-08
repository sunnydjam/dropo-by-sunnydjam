package dropoandroid

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
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
