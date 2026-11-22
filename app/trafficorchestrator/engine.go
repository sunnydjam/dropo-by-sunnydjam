package trafficorchestrator

import (
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"
)

var ErrBackendClosed = errors.New("packet backend closed")

// PacketAddress is the ABI-neutral 80-byte WinDivert address record. The
// fields are intentionally opaque to the processor; the backend owns them.
type PacketAddress struct {
	Timestamp int64
	Flags     uint32
	Reserved  uint32
	Data      [64]byte
}

const winDivertAddressOutboundFlag uint32 = 1 << 17

func (address *PacketAddress) setDirection(direction PacketDirection) {
	if address == nil {
		return
	}
	switch direction {
	case PacketDirectionInbound:
		address.Flags &^= winDivertAddressOutboundFlag
	case PacketDirectionOutbound:
		address.Flags |= winDivertAddressOutboundFlag
	}
}

type PacketBackend interface {
	Receive([]byte) (int, PacketAddress, error)
	Send([]byte, *PacketAddress) error
	Close() error
}

// PacketBatchBackend can reinject one complete transformed decision in a
// single driver call. Strategies such as Flowseal ALT intentionally emit many
// bounded decoys around two real TCP segments; sending every packet with a
// separate syscall can starve unrelated direct TLS handshakes in the same
// WinDivert queue.
type PacketBatchBackend interface {
	SendBatch([][]byte, []PacketAddress) error
}

type EngineStats struct {
	CapturedPackets    uint64
	ReinjectedPackets  uint64
	BatchCalls         uint64
	SlowDecisions      uint64
	MaxDecisionMicros  uint64
	MaxDecisionOutputs uint64
}

type EngineState string

const (
	EngineStopped  EngineState = "stopped"
	EngineStarting EngineState = "starting"
	EngineRunning  EngineState = "running"
	EngineFailed   EngineState = "failed"
)

// Engine owns exactly one PacketBackend handle and one receive loop.
type Engine struct {
	backend   PacketBackend
	processor *Processor
	logger    func(string)

	stateMu sync.Mutex
	state   EngineState
	done    chan struct{}
	runErr  error
	closed  atomic.Bool

	capturedPackets    atomic.Uint64
	reinjectedPackets  atomic.Uint64
	batchCalls         atomic.Uint64
	slowDecisions      atomic.Uint64
	maxDecisionMicros  atomic.Uint64
	maxDecisionOutputs atomic.Uint64
}

const slowPacketDecisionThreshold = 5 * time.Millisecond

func NewEngine(backend PacketBackend, processor *Processor, logger func(string)) (*Engine, error) {
	if backend == nil {
		return nil, errors.New("packet backend is required")
	}
	if processor == nil {
		return nil, errors.New("packet processor is required")
	}
	return &Engine{backend: backend, processor: processor, logger: logger, state: EngineStopped}, nil
}

func (e *Engine) Start() error {
	e.stateMu.Lock()
	defer e.stateMu.Unlock()
	if e.closed.Load() {
		return ErrBackendClosed
	}
	if e.state != EngineStopped {
		return fmt.Errorf("engine cannot start from state %s", e.state)
	}
	e.state = EngineStarting
	e.done = make(chan struct{})
	e.runErr = nil
	go e.run()
	e.state = EngineRunning
	e.log(fmt.Sprintf("traffic engine started with plan revision %d", e.processor.Revision()))
	return nil
}

func (e *Engine) ApplyPlan(plan TrafficPlan) error {
	if e == nil || e.processor == nil {
		return errors.New("engine is not initialized")
	}
	if err := e.processor.ApplyPlan(plan); err != nil {
		return err
	}
	e.log(fmt.Sprintf("traffic plan revision %d applied atomically", plan.Revision))
	return nil
}

func (e *Engine) State() EngineState {
	if e == nil {
		return EngineStopped
	}
	e.stateMu.Lock()
	defer e.stateMu.Unlock()
	return e.state
}

func (e *Engine) Wait() error {
	if e == nil {
		return nil
	}
	e.stateMu.Lock()
	done := e.done
	e.stateMu.Unlock()
	if done == nil {
		return nil
	}
	<-done
	e.stateMu.Lock()
	defer e.stateMu.Unlock()
	return e.runErr
}

func (e *Engine) Stats() EngineStats {
	if e == nil {
		return EngineStats{}
	}
	return EngineStats{
		CapturedPackets:    e.capturedPackets.Load(),
		ReinjectedPackets:  e.reinjectedPackets.Load(),
		BatchCalls:         e.batchCalls.Load(),
		SlowDecisions:      e.slowDecisions.Load(),
		MaxDecisionMicros:  e.maxDecisionMicros.Load(),
		MaxDecisionOutputs: e.maxDecisionOutputs.Load(),
	}
}

func (e *Engine) Stop() error {
	if e == nil {
		return nil
	}
	if e.closed.Swap(true) {
		return nil
	}
	closeErr := e.backend.Close()
	e.stateMu.Lock()
	done := e.done
	e.stateMu.Unlock()
	if done != nil {
		<-done
		e.stateMu.Lock()
		runErr := e.runErr
		e.stateMu.Unlock()
		if runErr != nil && !errors.Is(runErr, ErrBackendClosed) && closeErr == nil {
			closeErr = runErr
		}
	}
	e.stateMu.Lock()
	e.state = EngineStopped
	e.stateMu.Unlock()
	e.log("traffic engine stopped")
	return closeErr
}

func (e *Engine) run() {
	buffer := make([]byte, 65535)
	var runErr error
	defer func() {
		e.stateMu.Lock()
		e.runErr = runErr
		if runErr != nil && !errors.Is(runErr, ErrBackendClosed) {
			e.state = EngineFailed
		} else if e.state != EngineStopped {
			e.state = EngineStopped
		}
		e.stateMu.Unlock()
		stats := e.Stats()
		e.log(fmt.Sprintf("traffic engine load: captured=%d reinjected=%d batches=%d slow_decisions=%d max_decision_us=%d max_outputs=%d",
			stats.CapturedPackets, stats.ReinjectedPackets, stats.BatchCalls, stats.SlowDecisions, stats.MaxDecisionMicros, stats.MaxDecisionOutputs))
		close(e.done)
	}()
	for {
		length, address, err := e.backend.Receive(buffer)
		if err != nil {
			runErr = err
			return
		}
		if length <= 0 || length > len(buffer) {
			continue
		}
		e.capturedPackets.Add(1)
		original := append([]byte(nil), buffer[:length]...)
		decisionStarted := time.Now()
		decision := e.processor.Process(original)
		decisionElapsed := time.Since(decisionStarted)
		decisionMicros := uint64(decisionElapsed.Microseconds())
		storeAtomicMaximum(&e.maxDecisionMicros, decisionMicros)
		storeAtomicMaximum(&e.maxDecisionOutputs, uint64(len(decision.Packets)))
		if decisionElapsed >= slowPacketDecisionThreshold {
			e.slowDecisions.Add(1)
		}
		if decision.Dropped {
			continue
		}
		if batch, ok := e.backend.(PacketBatchBackend); ok && len(decision.Packets) > 1 {
			addresses := make([]PacketAddress, len(decision.Packets))
			for index := range addresses {
				addresses[index] = address
				addresses[index].setDirection(decision.Direction)
			}
			if err := batch.SendBatch(decision.Packets, addresses); err != nil {
				// A transformed sequence is atomic from the engine's perspective.
				// Preserve the historical fail-safe attempt before stopping the
				// engine if a driver batch cannot be sent.
				_ = e.backend.Send(original, &address)
				runErr = fmt.Errorf("send packet batch: %w", err)
				return
			}
			e.batchCalls.Add(1)
			e.reinjectedPackets.Add(uint64(len(decision.Packets)))
			continue
		}
		for index, packet := range decision.Packets {
			outputAddress := address
			outputAddress.setDirection(decision.Direction)
			if err := e.backend.Send(packet, &outputAddress); err != nil {
				// The original packet is the only safe fallback. Try it once if a
				// synthetic/segmented send failed before ending the engine.
				if index < len(decision.Packets)-1 || decision.Transformed {
					_ = e.backend.Send(original, &address)
				}
				runErr = fmt.Errorf("send packet: %w", err)
				return
			}
			e.reinjectedPackets.Add(1)
		}
	}
}

func storeAtomicMaximum(target *atomic.Uint64, value uint64) {
	if target == nil {
		return
	}
	for current := target.Load(); value > current; current = target.Load() {
		if target.CompareAndSwap(current, value) {
			return
		}
	}
}

func (e *Engine) log(message string) {
	if e != nil && e.logger != nil {
		e.logger(message)
	}
}
