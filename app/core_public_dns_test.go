package main

import (
	"context"
	"net/netip"
	"os"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

func TestParsePublicDNSAnswerRejectsFakeAndKeepsPublicAddresses(t *testing.T) {
	const id = 0x4d21
	name, err := dnsmessage.NewName("updates.discord.com.")
	if err != nil {
		t.Fatal(err)
	}
	builder := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: id, Response: true, RecursionAvailable: true})
	if err := builder.StartQuestions(); err != nil {
		t.Fatal(err)
	}
	if err := builder.Question(dnsmessage.Question{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}); err != nil {
		t.Fatal(err)
	}
	if err := builder.StartAnswers(); err != nil {
		t.Fatal(err)
	}
	header := dnsmessage.ResourceHeader{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 30}
	if err := builder.AResource(header, dnsmessage.AResource{A: [4]byte{198, 18, 1, 10}}); err != nil {
		t.Fatal(err)
	}
	if err := builder.AResource(header, dnsmessage.AResource{A: [4]byte{162, 159, 137, 232}}); err != nil {
		t.Fatal(err)
	}
	message, err := builder.Finish()
	if err != nil {
		t.Fatal(err)
	}
	addresses, err := parsePublicDNSAnswer(message, id)
	if err != nil {
		t.Fatal(err)
	}
	if len(addresses) != 1 || addresses[0] != netip.MustParseAddr("162.159.137.232") {
		t.Fatalf("filtered DNS addresses = %v", addresses)
	}
}

func TestLookupPublicHostWithoutHostsIntegration(t *testing.T) {
	if os.Getenv("DROPO_DNS_INTEGRATION") != "1" {
		t.Skip("set DROPO_DNS_INTEGRATION=1 for the local network integration check")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	addresses, err := lookupPublicHostWithoutHosts(ctx, "updates.discord.com")
	if err != nil {
		t.Fatal(err)
	}
	if len(addresses) == 0 {
		t.Fatal("Discord updater returned no public address")
	}
	for _, address := range addresses {
		if !zapretPublicAddress(address) || dropoFakeIPv4Prefix.Contains(address) {
			t.Fatalf("unsafe integration address returned: %s", address)
		}
	}
}

func TestParsePublicDNSAnswerRejectsMismatchedTransaction(t *testing.T) {
	builder := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: 7, Response: true})
	message, err := builder.Finish()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := parsePublicDNSAnswer(message, 8); err == nil {
		t.Fatal("mismatched DNS transaction was accepted")
	}
}
