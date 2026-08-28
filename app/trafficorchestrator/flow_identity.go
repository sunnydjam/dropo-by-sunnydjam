package trafficorchestrator

import "net/netip"

// FlowTuple identifies one outbound transport flow before any Dropo packet
// action is applied. It deliberately contains no mutable routing state.
type FlowTuple struct {
	Network         Network
	Source          netip.Addr
	SourcePort      uint16
	Destination     netip.Addr
	DestinationPort uint16
}

// FlowIdentityResolver supplies optional, strongly observed process evidence.
// Returning an empty string is the required fail-safe result for an unknown,
// expired or inaccessible process.
type FlowIdentityResolver interface {
	ResolveProcessName(FlowTuple) string
}

func (tuple FlowTuple) valid() bool {
	return (tuple.Network == NetworkTCP || tuple.Network == NetworkUDP) &&
		tuple.Source.IsValid() && tuple.Destination.IsValid() &&
		tuple.Source.BitLen() == tuple.Destination.BitLen() &&
		tuple.SourcePort != 0 && tuple.DestinationPort != 0
}
