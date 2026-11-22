//go:build !windows

package trafficorchestrator

// Process attribution is currently available only through Windows IP Helper.
func NewWindowsFlowIdentityResolver() FlowIdentityResolver {
	return nil
}
