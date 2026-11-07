package dropoandroid

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	core "dropocore"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/sagernet/sing-box/adapter"
	tf "github.com/sagernet/sing-box/common/tlsfragment"
	"github.com/sagernet/sing-box/protocol/group"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

type adaptiveService struct {
	Tag     string   `json:"tag"`
	Targets []string `json:"targets"`
}

func (s *CommandServer) startAdaptiveLocked(ctx context.Context, generation uint64, coreGeneration int64, outbounds adapter.OutboundManager) {
	var plan struct {
		Generation int64             `json:"generation"`
		Services   []adaptiveService `json:"services"`
	}
	if json.Unmarshal([]byte(core.AndroidAdaptivePlan()), &plan) != nil || plan.Generation != coreGeneration || len(plan.Services) > 16 {
		return
	}
	s.adaptiveSelectors = map[string]*group.Selector{}
	s.adaptiveSelected = map[string]bool{}
	s.adaptiveNext = map[string]int64{}
	s.adaptiveHealthIndex = map[string]int{}
	services := []adaptiveService{}
	for _, service := range plan.Services {
		o, ok := outbounds.Outbound(core.AndroidAdaptiveSelectorPrefix + service.Tag)
		selector, valid := o.(*group.Selector)
		if !ok || !valid || !selector.SelectOutbound("proxy") {
			continue
		}
		s.adaptiveSelectors[service.Tag] = selector
		services = append(services, service)
	}
	direct, ok := outbounds.Outbound("direct")
	if !ok || len(services) == 0 {
		return
	}
	s.adaptiveWake = make(chan struct{}, 1)
	wake := s.adaptiveWake
	go s.runAdaptive(ctx, generation, coreGeneration, services, direct, wake)
}
func (s *CommandServer) resetAdaptiveLocked() {
	if s.adaptiveCycleCancel != nil {
		s.adaptiveCycleCancel()
		s.adaptiveCycleCancel = nil
	}
	for _, selector := range s.adaptiveSelectors {
		selector.SelectOutbound("proxy")
	}
	s.adaptiveSelected = map[string]bool{}
	s.adaptiveNext = map[string]int64{}
	s.adaptiveHealthIndex = map[string]int{}
	core.ResetAndroidAdaptive(s.sourceCoreGeneration)
}
func (s *CommandServer) beginAdaptiveCycle(ctx context.Context, generation uint64) (context.Context, context.CancelFunc) {
	s.sourceMu.Lock()
	defer s.sourceMu.Unlock()
	cycle, cancel := context.WithTimeout(ctx, 120*time.Second)
	if generation != s.sourceGeneration || ctx.Err() != nil {
		cancel()
		return cycle, cancel
	}
	if s.adaptiveCycleCancel != nil {
		s.adaptiveCycleCancel()
	}
	s.adaptiveCycleCancel = cancel
	return cycle, cancel
}
func (s *CommandServer) adaptiveProbeDue(ctx context.Context, generation uint64, tag string) (bool, int, bool) {
	s.sourceMu.Lock()
	defer s.sourceMu.Unlock()
	// A cancelled worker may still be draining its queue while a new session
	// starts. It must not postpone that session's probes through shared cooldowns.
	if ctx.Err() != nil || generation != s.sourceGeneration {
		return false, 0, false
	}
	now := time.Now().Unix()
	if now < s.adaptiveNext[tag] {
		return false, 0, false
	}
	active := s.adaptiveSelected[tag]
	index := s.adaptiveHealthIndex[tag]
	if active {
		s.adaptiveNext[tag] = now + 120
		s.adaptiveHealthIndex[tag] = index + 1
	} else {
		s.adaptiveNext[tag] = now + 900
	}
	return active, index, true
}
func (s *CommandServer) commitAdaptive(ctx context.Context, generation uint64, coreGeneration int64, tag string, successes int) bool {
	s.sourceMu.Lock()
	defer s.sourceMu.Unlock()
	if ctx.Err() != nil || generation != s.sourceGeneration {
		return false
	}
	selector := s.adaptiveSelectors[tag]
	if selector == nil {
		return false
	}
	if !core.CommitAndroidAdaptive(coreGeneration, tag, successes, sourceSelector{selector}) {
		return false
	}
	s.adaptiveSelected[tag] = successes == 3
	if successes == 3 {
		s.adaptiveNext[tag] = time.Now().Unix() + 120
	} else {
		s.adaptiveNext[tag] = time.Now().Unix() + 900
	}
	return true
}

func (s *CommandServer) runAdaptive(ctx context.Context, generation uint64, coreGeneration int64, services []adaptiveService, direct N.Dialer, wake <-chan struct{}) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	initial := true
	for {
		if !initial {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			case <-wake:
			}
		}
		if !core.AndroidSourceSessionCurrent(coreGeneration) {
			return
		}
		cycle, cancel := s.beginAdaptiveCycle(ctx, generation)
		jobs := make(chan adaptiveService)
		var workers sync.WaitGroup
		for range 2 {
			workers.Add(1)
			go func() {
				defer workers.Done()
				for service := range jobs {
					active, index, due := s.adaptiveProbeDue(cycle, generation, service.Tag)
					if !due {
						continue
					}
					probe := func(ctx context.Context, target string) error { return probeAdaptiveHTTP(ctx, target, direct) }
					if active {
						// Confirm a complete-target failure twice, then immediately restore VPN
						// for this service and interrupt its old direct connections.
						target := []string{service.Targets[index%len(service.Targets)]}
						if probeAdaptiveAttempts(cycle, target, 1, probe) != nil && cycle.Err() == nil && probeAdaptiveAttempts(cycle, target, 1, probe) != nil && cycle.Err() == nil {
							s.commitAdaptive(cycle, generation, coreGeneration, service.Tag, 0)
						}
					} else if probeAdaptiveAttempts(cycle, service.Targets, 3, probe) == nil {
						s.commitAdaptive(cycle, generation, coreGeneration, service.Tag, 3)
					}
				}
			}()
		}
	enqueue:
		for _, service := range services {
			select {
			case <-cycle.Done():
				break enqueue
			case jobs <- service:
			}
		}
		close(jobs)
		workers.Wait()
		cancel()
		initial = false
	}
}

func probeAdaptiveAttempts(ctx context.Context, targets []string, attempts int, probe func(context.Context, string) error) error {
	if len(targets) == 0 || len(targets) > 6 || attempts < 1 || attempts > 3 {
		return errors.New("invalid adaptive probe plan")
	}
	for attempt := 0; attempt < attempts; attempt++ {
		for _, target := range targets {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			one, cancel := context.WithTimeout(ctx, 4*time.Second)
			err := probe(one, target)
			cancel()
			if err != nil {
				return err
			}
		}
		if attempt+1 < attempts {
			timer := time.NewTimer(250 * time.Millisecond)
			select {
			case <-ctx.Done():
				timer.Stop()
				return ctx.Err()
			case <-timer.C:
			}
		}
	}
	return nil
}

func probeAdaptiveHTTP(ctx context.Context, target string, direct N.Dialer) error {
	return probeAdaptiveHTTPWithRoots(ctx, target, direct, nil)
}
func probeAdaptiveHTTPWithRoots(ctx context.Context, target string, direct N.Dialer, roots *x509.CertPool) error {
	transport := &http.Transport{Proxy: nil, DisableKeepAlives: true, TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: roots}, DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
		conn, err := direct.DialContext(ctx, N.NetworkTCP, M.ParseSocksaddr(address))
		if err != nil {
			return nil, err
		}
		return tf.NewConn(conn, ctx, false, true, 0), nil
	}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	req, err := http.NewRequestWithContext(ctx, "GET", target, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "Dropo-Android-service-check")
	response, err := client.Do(req)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 400 {
		return errors.New("service probe rejected")
	}
	_, err = io.CopyN(io.Discard, response.Body, 1024)
	if errors.Is(err, io.EOF) {
		err = nil
	}
	return err
}
