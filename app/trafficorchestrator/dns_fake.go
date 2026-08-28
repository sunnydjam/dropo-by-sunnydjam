package trafficorchestrator

import (
	"encoding/binary"
	"errors"
	"strings"
)

const (
	dnsTypeA     = 1
	dnsTypeAAAA  = 28
	dnsTypeHTTPS = 65
	dnsClassIN   = 1
	dnsFakeTTL   = 30
)

type DNSFakeResponder struct {
	directory *FakeIPDirectory
}

func NewDNSFakeResponder(directory *FakeIPDirectory) *DNSFakeResponder {
	return &DNSFakeResponder{directory: directory}
}

// Respond synthesizes an inbound DNS answer only for selected VPN domains.
// All other queries are returned as handled=false and pass unchanged. AAAA and
// HTTPS/SVCB hints receive NODATA so a client cannot bypass the fake IPv4 path.
func (responder *DNSFakeResponder) Respond(parsed parsedPacket) ([]byte, FakeIPTarget, bool, error) {
	if responder == nil || responder.directory == nil || parsed.network != NetworkUDP || parsed.destinationPort != 53 {
		return nil, FakeIPTarget{}, false, nil
	}
	payload := parsed.payload()
	questionEnd, host, queryType, queryClass, err := parseDNSQuestion(payload)
	if err != nil || queryClass != dnsClassIN {
		return nil, FakeIPTarget{}, false, nil
	}
	if queryType != dnsTypeA && queryType != dnsTypeAAAA && queryType != dnsTypeHTTPS {
		return nil, FakeIPTarget{}, false, nil
	}
	target, matched := responder.directory.ResolveHost(host)
	if !matched {
		return nil, FakeIPTarget{}, false, nil
	}

	answerCount := uint16(0)
	responsePayload := make([]byte, questionEnd)
	copy(responsePayload, payload[:questionEnd])
	// Standard response, recursion desired/available, no error. Preserve only
	// the request ID; request flags and additional records are untrusted input.
	responseFlags := uint16(0x8180)
	binary.BigEndian.PutUint16(responsePayload[2:4], responseFlags)
	binary.BigEndian.PutUint16(responsePayload[4:6], 1)
	binary.BigEndian.PutUint16(responsePayload[8:10], 0)
	binary.BigEndian.PutUint16(responsePayload[10:12], 0)
	if matched && queryType == dnsTypeA {
		answerCount = 1
		answer := make([]byte, 16)
		binary.BigEndian.PutUint16(answer[0:2], 0xc00c)
		binary.BigEndian.PutUint16(answer[2:4], dnsTypeA)
		binary.BigEndian.PutUint16(answer[4:6], dnsClassIN)
		binary.BigEndian.PutUint32(answer[6:10], dnsFakeTTL)
		binary.BigEndian.PutUint16(answer[10:12], 4)
		address := target.Address.As4()
		copy(answer[12:16], address[:])
		responsePayload = append(responsePayload, answer...)
	}
	binary.BigEndian.PutUint16(responsePayload[6:8], answerCount)

	packet, responseParsed, err := resizePacketPayload(parsed, responsePayload)
	if err != nil {
		return nil, FakeIPTarget{}, true, err
	}
	swapPacketAddresses(packet, responseParsed)
	binary.BigEndian.PutUint16(packet[responseParsed.transportOffset:responseParsed.transportOffset+2], uint16(parsed.destinationPort))
	binary.BigEndian.PutUint16(packet[responseParsed.transportOffset+2:responseParsed.transportOffset+4], uint16(parsed.sourcePort))
	calculateChecksums(packet)
	return packet, target, true, nil
}

func parseDNSQuestion(payload []byte) (end int, host string, queryType, queryClass uint16, err error) {
	if len(payload) < 17 {
		return 0, "", 0, 0, errors.New("DNS query is truncated")
	}
	flags := binary.BigEndian.Uint16(payload[2:4])
	if flags&0x8000 != 0 || flags&0x7800 != 0 || binary.BigEndian.Uint16(payload[4:6]) != 1 {
		return 0, "", 0, 0, errors.New("DNS message is not one standard query")
	}
	labels := make([]string, 0, 8)
	cursor := 12
	totalNameLength := 0
	for {
		if cursor >= len(payload) {
			return 0, "", 0, 0, errors.New("DNS question name is truncated")
		}
		length := int(payload[cursor])
		cursor++
		if length == 0 {
			break
		}
		if length&0xc0 != 0 || length > 63 || cursor+length > len(payload) {
			return 0, "", 0, 0, errors.New("DNS question name is invalid")
		}
		label := string(payload[cursor : cursor+length])
		if strings.IndexFunc(label, func(r rune) bool {
			return !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-')
		}) >= 0 {
			return 0, "", 0, 0, errors.New("DNS label contains unsupported characters")
		}
		labels = append(labels, label)
		totalNameLength += length + 1
		if totalNameLength > 253 || len(labels) > 32 {
			return 0, "", 0, 0, errors.New("DNS question name is too long")
		}
		cursor += length
	}
	if len(labels) == 0 || cursor+4 > len(payload) {
		return 0, "", 0, 0, errors.New("DNS question is incomplete")
	}
	host = normalizeHost(strings.Join(labels, "."))
	if host == "" {
		return 0, "", 0, 0, errors.New("DNS question host is invalid")
	}
	queryType = binary.BigEndian.Uint16(payload[cursor : cursor+2])
	queryClass = binary.BigEndian.Uint16(payload[cursor+2 : cursor+4])
	return cursor + 4, host, queryType, queryClass, nil
}
