//go:build !windows

package main

import traffic "dropo/trafficorchestrator"

type noopSelectiveProxyLease struct{}

func prepareSelectiveProxyRouting(_ traffic.TrafficPlan, _ string) (selectiveProxyRoutingLease, error) {
	return noopSelectiveProxyLease{}, nil
}

func (noopSelectiveProxyLease) Restore() error                   { return nil }
func (noopSelectiveProxyLease) PACURL() string                   { return "" }
func (noopSelectiveProxyLease) DomainCount() int                 { return 0 }
func (noopSelectiveProxyLease) Update(traffic.TrafficPlan) error { return nil }
