package trafficorchestrator

import (
	"container/list"
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
	order    *list.Element
}

type flowDecisionTable struct {
	mu      sync.Mutex
	entries map[FlowTuple]cachedFlowDecision
	order   list.List
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
	entry, found := table.entries[tuple]
	if found {
		table.order.MoveToFront(entry.order)
	} else {
		if len(table.entries) >= maxFlowDecisions {
			oldest := table.order.Back()
			delete(table.entries, oldest.Value.(FlowTuple))
			table.order.Remove(oldest)
		}
		entry.order = table.order.PushFront(tuple)
	}
	entry.decision = decision
	entry.expires = table.now().Add(flowDecisionTTL(tuple))
	table.entries[tuple] = entry
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
			table.order.Remove(entry.order)
			delete(table.entries, tuple)
		}
		return FlowDecision{}, false
	}
	table.order.MoveToFront(entry.order)
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

// An established direct stream cannot be spliced into a relay midstream.
func (table *flowDecisionTable) advanceRevision(revision uint64) {
	table.mu.Lock()
	defer table.mu.Unlock()
	now := table.now()
	for key, entry := range table.entries {
		if entry.decision.Disposition == FlowDirect && now.Before(entry.expires) {
			entry.decision.PlanRevision = revision
			table.entries[key] = entry
		} else {
			table.order.Remove(entry.order)
			delete(table.entries, key)
		}
	}
}
