package main

import "testing"

func TestParseSourceAcceptsMultipleDirectLinks(t *testing.T) {
	const bundle = "vless://11111111-1111-1111-1111-111111111111@one.example:443?security=tls&type=tcp#One\r\n" +
		"trojan://secret@two.example:443?security=tls&type=tcp#Two\n"

	proxies, err := NewSubscriptionFetcher().ParseSource(bundle)
	if err != nil {
		t.Fatalf("ParseSource() error = %v", err)
	}
	if len(proxies) != 2 {
		t.Fatalf("ParseSource() returned %d proxies, want 2: %#v", len(proxies), proxies)
	}
	if proxies[0].Name != "One" || proxies[0].Server != "one.example" {
		t.Fatalf("first proxy = %#v, want clean first VLESS node", proxies[0])
	}
	if proxies[1].Name != "Two" || proxies[1].Server != "two.example" {
		t.Fatalf("second proxy = %#v, want clean second Trojan node", proxies[1])
	}
	if proxies[0].Raw == bundle {
		t.Fatal("first node retained the complete multiline bundle as its raw link")
	}
}

func TestVLESSHTTPUpgradePreservesHostAndPath(t *testing.T) {
	proxy, err := parseVLESS("vless://00000000-0000-0000-0000-000000000001@edge.example:443?security=tls&sni=origin.example&type=httpupgrade&host=upgrade.example&path=%2Ftransport#HTTPUpgrade")
	if err != nil {
		t.Fatalf("parseVLESS() error = %v", err)
	}

	outbound := proxy.ToSingboxOutbound()
	transport, ok := outbound["transport"].(map[string]interface{})
	if !ok {
		t.Fatalf("transport = %#v, want map", outbound["transport"])
	}
	if got := transport["type"]; got != "httpupgrade" {
		t.Fatalf("transport type = %#v, want httpupgrade", got)
	}
	if got := transport["path"]; got != "/transport" {
		t.Fatalf("transport path = %#v, want /transport", got)
	}
	if got := transport["host"]; got != "upgrade.example" {
		t.Fatalf("transport host = %#v, want upgrade.example", got)
	}
	if _, exists := transport["headers"]; exists {
		t.Fatalf("HTTPUpgrade transport must not encode host as WebSocket headers: %#v", transport)
	}
}

func TestVLESSHTTPUpgradeOmitsEmptyOptionalFields(t *testing.T) {
	proxy := ProxyConfig{
		Type:       "vless",
		Tag:        "vpn-source-test",
		Server:     "edge.example",
		ServerPort: 443,
		UUID:       "00000000-0000-0000-0000-000000000001",
		Network:    "httpupgrade",
	}

	transport, ok := proxy.ToSingboxOutbound()["transport"].(map[string]interface{})
	if !ok {
		t.Fatal("HTTPUpgrade transport was not generated")
	}
	if _, exists := transport["path"]; exists {
		t.Fatalf("empty path must be omitted: %#v", transport)
	}
	if _, exists := transport["host"]; exists {
		t.Fatalf("empty host must be omitted: %#v", transport)
	}
}
