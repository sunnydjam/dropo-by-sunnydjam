package trafficorchestrator

import (
	"encoding/binary"
	"net/netip"
	"strings"
	"testing"
)

func TestDNSFakeResponderSynthesizesOnlySelectedVPNDomains(t *testing.T) {
	directory, err := NewFakeIPDirectory(fakeIPTestPlan())
	if err != nil {
		t.Fatal(err)
	}
	responder := NewDNSFakeResponder(directory)
	query := testDNSQueryPacket(t, "www.youtube.com", dnsTypeA)
	parsedQuery, err := parsePacket(query)
	if err != nil {
		t.Fatal(err)
	}
	response, target, handled, err := responder.Respond(parsedQuery)
	if err != nil || !handled {
		t.Fatalf("Respond() handled=%t err=%v", handled, err)
	}
	if target.ServiceID != "youtube" || target.Host != "www.youtube.com" {
		t.Fatalf("fake target = %+v", target)
	}
	parsedResponse, err := parsePacket(response)
	if err != nil {
		t.Fatal(err)
	}
	if parsedResponse.source != netip.MustParseAddr("8.8.8.8") || parsedResponse.destination != netip.MustParseAddr("192.0.2.1") || parsedResponse.sourcePort != 53 || parsedResponse.destinationPort != 53000 {
		t.Fatalf("DNS response tuple = %+v", parsedResponse.flowTuple())
	}
	payload := parsedResponse.payload()
	if binary.BigEndian.Uint16(payload[6:8]) != 1 || len(payload) < 4 || !target.Address.Is4() {
		t.Fatalf("DNS answer count/payload = %d/%d", binary.BigEndian.Uint16(payload[6:8]), len(payload))
	}
	address := target.Address.As4()
	if got := payload[len(payload)-4:]; string(got) != string(address[:]) {
		t.Fatalf("DNS A answer = %v, want %v", got, address)
	}

	directQuery, _ := parsePacket(testDNSQueryPacket(t, "chatgpt.com", dnsTypeA))
	if _, _, handled, err := responder.Respond(directQuery); handled || err != nil {
		t.Fatalf("direct DNS query handled=%t err=%v", handled, err)
	}
}

func TestDNSFakeResponderReturnsNoDataForSelectedAAAA(t *testing.T) {
	directory, err := NewFakeIPDirectory(fakeIPTestPlan())
	if err != nil {
		t.Fatal(err)
	}
	query, _ := parsePacket(testDNSQueryPacket(t, "www.youtube.com", dnsTypeAAAA))
	response, _, handled, err := NewDNSFakeResponder(directory).Respond(query)
	if err != nil || !handled {
		t.Fatalf("AAAA handled=%t err=%v", handled, err)
	}
	parsed, err := parsePacket(response)
	if err != nil {
		t.Fatal(err)
	}
	if answers := binary.BigEndian.Uint16(parsed.payload()[6:8]); answers != 0 {
		t.Fatalf("AAAA answer count = %d, want NODATA", answers)
	}
}

func TestProcessorSynthesizesInboundFakeDNSResponse(t *testing.T) {
	plan := fakeIPTestPlan()
	directory, err := NewFakeIPDirectory(plan)
	if err != nil {
		t.Fatal(err)
	}
	processor, err := NewProcessorWithSelectiveRuntime(plan, nil, nil, directory)
	if err != nil {
		t.Fatal(err)
	}
	decision := processor.Process(testDNSQueryPacket(t, "www.youtube.com", dnsTypeA))
	if decision.Dropped || !decision.Transformed || decision.Direction != PacketDirectionInbound || decision.ServiceID != "youtube" || decision.Route != ServiceRouteVPN || !strings.Contains(decision.Reason, "fake IP") {
		t.Fatalf("fake DNS decision = %+v", decision)
	}
}

func TestProcessorLeavesDoHBootstrapDNSDirect(t *testing.T) {
	plan := fakeIPTestPlan()
	directory, err := NewFakeIPDirectory(plan)
	if err != nil {
		t.Fatal(err)
	}
	processor, err := NewProcessorWithSelectiveRuntime(plan, nil, nil, directory)
	if err != nil {
		t.Fatal(err)
	}
	original := testDNSQueryPacket(t, "dns.google", dnsTypeA)
	decision := processor.Process(original)
	if decision.Dropped || decision.Transformed || len(decision.Packets) != 1 || string(decision.Packets[0]) != string(original) {
		t.Fatalf("DoH bootstrap DNS decision = %+v", decision)
	}
}

func TestSelectiveDNSDoesNotRewriteTrustedSingBoxResolution(t *testing.T) {
	plan := fakeIPTestPlan()
	directory, err := NewFakeIPDirectory(plan)
	if err != nil {
		t.Fatal(err)
	}
	resolver := &fixedFlowIdentityResolver{name: `C:\Program Files\dropo\resources\bin\sing-box.exe`}
	processor, err := NewProcessorWithSelectiveRuntime(plan, resolver, nil, directory)
	if err != nil {
		t.Fatal(err)
	}

	for _, host := range []string{"www.youtube.com", "dns.google"} {
		original := testDNSQueryPacket(t, host, dnsTypeA)
		decision := processor.Process(original)
		if decision.Dropped || decision.Transformed || len(decision.Packets) != 1 {
			t.Fatalf("trusted sing-box DNS %q decision = %+v", host, decision)
		}
		if string(decision.Packets[0]) != string(original) {
			t.Fatalf("trusted sing-box DNS %q was rewritten", host)
		}
	}

	originalTLS := testIPv4TCPPacketTo(t, "1.1.1.1", "dns.google")
	decision := processor.Process(originalTLS)
	if decision.Dropped || decision.Transformed || len(decision.Packets) != 1 || string(decision.Packets[0]) != string(originalTLS) {
		t.Fatalf("trusted sing-box DoH decision = %+v", decision)
	}
	selectedTLS := testIPv4TCPPacketTo(t, "203.0.113.80", "www.youtube.com")
	decision = processor.Process(selectedTLS)
	if decision.Dropped || decision.Transformed || len(decision.Packets) != 1 || string(decision.Packets[0]) != string(selectedTLS) || decision.Reason != "trusted Dropo runtime egress" {
		t.Fatalf("trusted sing-box selected-service egress decision = %+v", decision)
	}
}

func testDNSQueryPacket(t *testing.T, host string, queryType uint16) []byte {
	t.Helper()
	payload := make([]byte, 12)
	binary.BigEndian.PutUint16(payload[0:2], 0x1234)
	binary.BigEndian.PutUint16(payload[2:4], 0x0100)
	binary.BigEndian.PutUint16(payload[4:6], 1)
	for _, label := range strings.Split(host, ".") {
		if len(label) == 0 || len(label) > 63 {
			t.Fatalf("invalid test DNS label %q", label)
		}
		payload = append(payload, byte(len(label)))
		payload = append(payload, label...)
	}
	payload = append(payload, 0, 0, 0, 0, 0)
	binary.BigEndian.PutUint16(payload[len(payload)-4:len(payload)-2], queryType)
	binary.BigEndian.PutUint16(payload[len(payload)-2:], dnsClassIN)
	packet := testIPv4UDPPacket("8.8.8.8", 53, payload)
	binary.BigEndian.PutUint16(packet[20:22], 53000)
	calculateChecksums(packet)
	return packet
}
