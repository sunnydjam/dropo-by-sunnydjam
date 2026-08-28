//go:build !windows

package main

import traffic "dropo/trafficorchestrator"

type noopSelectiveNameResolutionLease struct{}

func prepareSelectiveNameResolution(_ traffic.TrafficPlan, _ *traffic.FakeIPDirectory) (selectiveNameResolutionLease, error) {
	return noopSelectiveNameResolutionLease{}, nil
}

func (noopSelectiveNameResolutionLease) Restore() error        { return nil }
func (noopSelectiveNameResolutionLease) DisabledMappings() int { return 0 }
func (noopSelectiveNameResolutionLease) PrimedMappings() int   { return 0 }
func (noopSelectiveNameResolutionLease) Update(selectiveNameResolutionPlan) error {
	return nil
}
