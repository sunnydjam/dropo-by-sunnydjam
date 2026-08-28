package trafficorchestrator

import (
	"encoding/binary"
	"errors"
)

type PacketDirection uint8

const (
	PacketDirectionPreserve PacketDirection = iota
	PacketDirectionInbound
	PacketDirectionOutbound
)

// TCPPacketRedirector performs only deterministic address/port reflection. The
// relay owns stream forwarding; the WinDivert backend remains the single packet
// handle owner.
type TCPPacketRedirector struct {
	registry  *TCPRedirectRegistry
	relayPort uint16
}

func NewTCPPacketRedirector(registry *TCPRedirectRegistry, relayPort int) (*TCPPacketRedirector, error) {
	if registry == nil {
		return nil, errors.New("TCP redirect registry is required")
	}
	if relayPort < 1 || relayPort > 65535 {
		return nil, errors.New("TCP relay port is outside 1..65535")
	}
	return &TCPPacketRedirector{registry: registry, relayPort: uint16(relayPort)}, nil
}

func (redirector *TCPPacketRedirector) ReflectClientPacket(parsed parsedPacket, target TCPRedirectTarget) ([]byte, error) {
	if redirector == nil || parsed.network != NetworkTCP || target.Flow != parsed.flowTuple() {
		return nil, errors.New("TCP packet does not match redirect target")
	}
	if !redirector.registry.contains(target) {
		if !parsed.isInitialTCPSYN() {
			return nil, errors.New("TCP redirect flow did not start with an initial SYN")
		}
		if err := redirector.registry.Register(target); err != nil {
			return nil, err
		}
	}
	packet := append([]byte(nil), parsed.bytes...)
	swapPacketAddresses(packet, parsed)
	binary.BigEndian.PutUint16(packet[parsed.transportOffset+2:parsed.transportOffset+4], redirector.relayPort)
	calculateChecksums(packet)
	return packet, nil
}

// RestoreRelayPacket rewrites an outbound relay response back into the remote
// service response expected by the original client TCP stack.
func (redirector *TCPPacketRedirector) RestoreRelayPacket(parsed parsedPacket) ([]byte, TCPRedirectTarget, bool, error) {
	if redirector == nil || parsed.network != NetworkTCP || parsed.sourcePort != int(redirector.relayPort) {
		return nil, TCPRedirectTarget{}, false, nil
	}
	target, ok := redirector.registry.lookupReflected(parsed.source, parsed.destination, uint16(parsed.destinationPort))
	if !ok {
		return nil, TCPRedirectTarget{}, true, errors.New("relay response has no active redirect flow")
	}
	packet := append([]byte(nil), parsed.bytes...)
	swapPacketAddresses(packet, parsed)
	binary.BigEndian.PutUint16(packet[parsed.transportOffset:parsed.transportOffset+2], target.Flow.DestinationPort)
	calculateChecksums(packet)
	return packet, target, true, nil
}

func (parsed parsedPacket) isInitialTCPSYN() bool {
	if parsed.network != NetworkTCP || parsed.tcpFlagsOffset < 0 || parsed.tcpFlagsOffset >= len(parsed.bytes) {
		return false
	}
	flags := parsed.bytes[parsed.tcpFlagsOffset]
	return flags&0x02 != 0 && flags&0x10 == 0
}

func swapPacketAddresses(packet []byte, parsed parsedPacket) {
	if parsed.ipVersion == 4 {
		var temporary [4]byte
		copy(temporary[:], packet[12:16])
		copy(packet[12:16], packet[16:20])
		copy(packet[16:20], temporary[:])
		return
	}
	var temporary [16]byte
	copy(temporary[:], packet[8:24])
	copy(packet[8:24], packet[24:40])
	copy(packet[24:40], temporary[:])
}
