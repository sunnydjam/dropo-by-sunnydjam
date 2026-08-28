package trafficorchestrator

import (
	"sync"
	"time"
)

const maxFlowDecisions = 8192

type FlowDisposition string

const (
	FlowDirect      FlowDisposition = "direct"
	FlowService     FlowDisposition = "service"
	FlowWorkNetwork FlowDisposition = "work_network"
)

// FlowDecision also preserves TCP stream consistency. Once a captured packet
// from an already-established flow has safely passed direct, later packets on
// that same tuple must not be spliced into the selective relay midstream.
type FlowDecision struct {
	PlanRevision uint64
	Disposition  FlowDisposition
	Route        ServiceRouteKind
	ServiceID    string
	RuleID       string
	ProcessName  string
	Reason       string
}

type cachedFlowDecision struct {
	decision FlowDecision
	expires  time.Time
}

type flowDecisionTable struct {
	mu      sync.Mutex
	entries map[FlowTuple]cachedFlowDecision
	now     func() time.Time
}

func newFlowDecisionTable() *flowDecisionTable {
	return &flowDecisionTable{entries: make(map[FlowTuple]cachedFlowDecision), now: time.Now}
}

func (table *flowDecisionTable) store(tuple FlowTuple, decision FlowDecision) {
	if table == nil || !tuple.valid() {
		return
	}
	table.mu.Lock()
	defer table.mu.Unlock()
	if len(table.entries) >= maxFlowDecisions {
		clear(table.entries)
	}
	table.entries[tuple] = cachedFlowDecision{decision: decision, expires: table.now().Add(flowDecisionTTL(tuple))}
}

func (table *flowDecisionTable) lookup(tuple FlowTuple, revision uint64) (FlowDecision, bool) {
	if table == nil || !tuple.valid() {
		return FlowDecision{}, false
	}
	table.mu.Lock()
	defer table.mu.Unlock()
	entry, ok := table.entries[tuple]
	now := table.now()
	if !ok || entry.decision.PlanRevision != revision || !now.Before(entry.expires) {
		if ok {
			delete(table.entries, tuple)
		}
		return FlowDecision{}, false
	}
	entry.expires = now.Add(flowDecisionTTL(tuple))
	table.entries[tuple] = entry
	return entry.decision, true
}

func flowDecisionTTL(tuple FlowTuple) time.Duration {
	if tuple.Network == NetworkUDP {
		return 30 * time.Second
	}
	return 2 * time.Minute
}

func (table *flowDecisionTable) clear() {
	if table == nil {
		return
	}
	table.mu.Lock()
	clear(table.entries)
	table.mu.Unlock()
}
