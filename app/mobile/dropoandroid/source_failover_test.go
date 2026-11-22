package dropoandroid

import (
	"context"
	"fmt"
	"net"
	"reflect"
	"testing"

	"github.com/gofrs/uuid/v5"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/trafficcontrol"
	N "github.com/sagernet/sing/common/network"
)

func TestConfirmedOutageCleanupRequiresFailedCurrentAndHealthyReplacement(t *testing.T) {
	active := sourceCandidate{ID: "main", NodeID: "main-node", Tag: "vpn-1"}
	reserve := sourceCandidate{ID: "reserve", NodeID: "reserve-node", Tag: "vpn-2"}
	candidates := []sourceCandidate{active, reserve}
	failed := sourceObservation{SourceID: active.ID, NodeID: active.NodeID, State: "failed"}
	healthy := sourceObservation{SourceID: reserve.ID, NodeID: reserve.NodeID, State: "ok", LatencyMS: 20}
	for _, tc := range []struct {
		name      string
		confirmed sourceCandidate
		selected  string
		results   []sourceObservation
		want      string
	}{
		{"outage", active, reserve.ID, []sourceObservation{failed, healthy}, active.Tag},
		{"initial latency choice", sourceCandidate{}, reserve.ID, []sourceObservation{failed, healthy}, ""},
		{"no replacement", active, "", []sourceObservation{failed}, ""},
		{"same source", active, active.ID, []sourceObservation{failed, healthy}, ""},
		{"foreign replacement", active, "unprepared", []sourceObservation{failed, healthy}, ""},
		{"active recovered", active, reserve.ID, []sourceObservation{{SourceID: active.ID, NodeID: active.NodeID, State: "ok", LatencyMS: 10}, healthy}, ""},
		{"replacement failed", active, reserve.ID, []sourceObservation{failed, {SourceID: reserve.ID, NodeID: reserve.NodeID, State: "failed"}}, ""},
		{"wrong node", active, reserve.ID, []sourceObservation{{SourceID: active.ID, NodeID: "sibling", State: "failed"}, healthy}, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := confirmedOutageSourceTag(tc.confirmed, candidates, tc.results, tc.selected); got != tc.want {
				t.Fatalf("cleanup tag = %q, want %q", got, tc.want)
			}
		})
	}
}

type fakeSourceFlow struct {
	metadata *trafficcontrol.TrackerMetadata
	closed   int
	onClose  func()
}

func (f *fakeSourceFlow) Metadata() *trafficcontrol.TrackerMetadata { return f.metadata }
func (f *fakeSourceFlow) Close() error {
	f.closed++
	if f.onClose != nil {
		f.onClose()
	}
	return nil
}

type fakeSourceFlows struct {
	snapshot  []*trafficcontrol.TrackerMetadata
	trackers  map[uuid.UUID]*fakeSourceFlow
	reported  int
	snapshots int
}

func (f *fakeSourceFlows) ConnectionsLen() int {
	if f.reported > 0 {
		return f.reported
	}
	return len(f.snapshot)
}
func (f *fakeSourceFlows) Connections() []*trafficcontrol.TrackerMetadata {
	f.snapshots++
	return f.snapshot
}
func (f *fakeSourceFlows) Connection(id uuid.UUID) trafficcontrol.Tracker {
	if tracker := f.trackers[id]; tracker != nil {
		return tracker
	}
	return nil
}
func (f *fakeSourceFlows) add(tag string) *fakeSourceFlow {
	id := uuid.FromStringOrNil(fmt.Sprintf("00000000-0000-0000-0000-%012d", len(f.snapshot)+1))
	flow := &fakeSourceFlow{metadata: &trafficcontrol.TrackerMetadata{ID: id, Chain: []string{tag, "proxy"}}}
	if f.trackers == nil {
		f.trackers = make(map[uuid.UUID]*fakeSourceFlow)
	}
	f.trackers[id] = flow
	f.snapshot = append(f.snapshot, flow.metadata)
	return flow
}

func TestSourceCleanupOnlyClosesExactFailedChainAfterSuccessfulCommit(t *testing.T) {
	for _, tc := range []struct {
		name               string
		committed, current bool
		tag                string
		want               int
	}{
		{"outage", true, true, "vpn-1", 1},
		{"failed selector commit", false, true, "vpn-1", 0},
		{"stopped generation", true, false, "vpn-1", 0},
		{"healthy selection", true, true, "", 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			table := &fakeSourceFlows{}
			failed := table.add("vpn-1")
			others := []*fakeSourceFlow{table.add("direct"), table.add("vpn-2"), table.add("personal"), table.add("vpn-10")}
			committed := false
			failed.onClose = func() {
				if !committed {
					t.Fatal("closed before selector commit")
				}
			}
			commitSourceAndCleanup(func() bool { return tc.current }, func() bool { committed = tc.committed; return committed }, table, tc.tag)
			if failed.closed != tc.want {
				t.Fatalf("closed %d, want %d", failed.closed, tc.want)
			}
			for _, flow := range others {
				if flow.closed != 0 {
					t.Fatal("healthy/direct/personal flow closed")
				}
			}
		})
	}
}

func TestSourceCleanupFencesCancellationAndRechecksLiveTracker(t *testing.T) {
	table := &fakeSourceFlows{}
	stale := table.add("vpn-1")
	stale.metadata = &trafficcontrol.TrackerMetadata{ID: stale.metadata.ID, Chain: []string{"vpn-2", "proxy"}}
	missing := table.add("vpn-1")
	delete(table.trackers, missing.metadata.ID)
	first := table.add("vpn-1")
	second := table.add("vpn-1")
	alive := true
	first.onClose = func() { alive = false }
	if n := closeFailedSourceFlows(table, "vpn-1", func() bool { return alive }); n != 1 {
		t.Fatalf("closed %d flows", n)
	}
	if stale.closed != 0 || missing.closed != 0 || first.closed != 1 || second.closed != 0 {
		t.Fatal("stale reference or cancelled generation closed a flow")
	}
	table = &fakeSourceFlows{}
	table.add("vpn-1")
	alive = true
	commitSourceAndCleanup(func() bool { return alive }, func() bool { alive = false; return true }, table, "vpn-1")
	if table.snapshots != 0 {
		t.Fatal("snapshot acquired after cancellation")
	}
}

func TestSourceCleanupSnapshotAndCloseBudgets(t *testing.T) {
	table := &fakeSourceFlows{}
	for range maxSourceFlowCloses + 1 {
		table.add("vpn-1")
	}
	if n := closeFailedSourceFlows(table, "vpn-1", func() bool { return true }); n != maxSourceFlowCloses {
		t.Fatalf("close budget = %d", n)
	}
	table = &fakeSourceFlows{reported: maxSourceFlowSnapshot + 1}
	table.add("vpn-1")
	if n := closeFailedSourceFlows(table, "vpn-1", func() bool { return true }); n != 0 || table.snapshots != 0 {
		t.Fatal("oversized traffic snapshot requested")
	}
	table = &fakeSourceFlows{reported: 1}
	for range maxSourceFlowSnapshot {
		table.add("direct")
	}
	tail := table.add("vpn-1")
	closeFailedSourceFlows(table, "vpn-1", func() bool { return true })
	if tail.closed != 0 {
		t.Fatal("snapshot race exceeded inspection budget")
	}
	table = &fakeSourceFlows{}
	flow := table.add("vpn-1")
	table.snapshot = append(table.snapshot, flow.metadata)
	closeFailedSourceFlows(table, "vpn-1", func() bool { return true })
	if flow.closed != 1 {
		t.Fatal("duplicate snapshot closed a flow twice")
	}
}

type taggedSourceOutbound struct {
	adapter.Outbound
	tag string
}

func (o taggedSourceOutbound) Tag() string  { return o.tag }
func (o taggedSourceOutbound) Type() string { return "fixture" }

type observedSourceConn struct {
	net.Conn
	closed int
}

func (c *observedSourceConn) Close() error { c.closed++; return c.Conn.Close() }

type observedSourcePacket struct {
	N.PacketConn
	closed int
}

func (c *observedSourcePacket) Close() error { c.closed++; return nil }

func TestSourceCleanupClosesRealPinnedTCPAndUDPTrackersOnly(t *testing.T) {
	manager := trafficcontrol.NewManager()
	metadata := func(tag, network string) adapter.InboundContext {
		return adapter.InboundContext{Network: network, OutboundChain: []adapter.Outbound{taggedSourceOutbound{tag: "proxy"}, taggedSourceOutbound{tag: tag}}}
	}
	first, peer := net.Pipe()
	defer peer.Close()
	tcp := &observedSourceConn{Conn: first}
	manager.RoutedConnection(context.Background(), tcp, metadata("vpn-1", "tcp"), nil, taggedSourceOutbound{tag: "vpn-1"})
	udp := &observedSourcePacket{}
	manager.RoutedPacketConnection(context.Background(), udp, metadata("vpn-1", "udp"), nil, taggedSourceOutbound{tag: "vpn-1"})
	other, otherPeer := net.Pipe()
	defer otherPeer.Close()
	healthy := &observedSourceConn{Conn: other}
	healthyTracker := manager.RoutedConnection(context.Background(), healthy, metadata("vpn-2", "tcp"), nil, taggedSourceOutbound{tag: "vpn-2"})
	defer healthyTracker.Close()
	if n := closeFailedSourceFlows(manager, "vpn-1", func() bool { return true }); n != 2 {
		t.Fatalf("closed %d real trackers", n)
	}
	if !reflect.DeepEqual([]int{tcp.closed, udp.closed, healthy.closed}, []int{1, 1, 0}) || manager.ConnectionsLen() != 1 {
		t.Fatal("pinned traffic manager did not release only failed TCP/UDP flows")
	}
}
