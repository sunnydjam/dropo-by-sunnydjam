package main

import (
	"fmt"
	"net"
	"testing"
)

func TestBuildXrayBridgeConfigSkipsBusyBridgePort(t *testing.T) {
	listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", XrayBridgePortStart))
	if err != nil {
		t.Skipf("cannot reserve test port %d: %v", XrayBridgePortStart, err)
	}
	defer listener.Close()

	result := BuildXrayBridgeConfig([]ProxyConfig{
		{
			Type:       "vless",
			Tag:        "xhttp-test",
			Name:       "xhttp-test",
			Server:     "example.com",
			ServerPort: 443,
			UUID:       "11111111-1111-1111-1111-111111111111",
			Network:    "xhttp",
			Security:   "tls",
		},
	})

	if len(result.SingBoxProxies) != 1 {
		t.Fatalf("sing-box bridge proxies = %#v, want one proxy", result.SingBoxProxies)
	}
	proxyPort := result.SingBoxProxies[0].ServerPort
	if proxyPort == XrayBridgePortStart {
		t.Fatalf("bridge reused busy port %d", XrayBridgePortStart)
	}

	inbounds, _ := result.XrayConfig["inbounds"].([]interface{})
	if len(inbounds) != 1 {
		t.Fatalf("xray inbounds = %#v, want one inbound", result.XrayConfig["inbounds"])
	}
	inbound, _ := inbounds[0].(map[string]interface{})
	if inbound["port"] != proxyPort {
		t.Fatalf("xray inbound port = %#v, want sing-box proxy port %d", inbound["port"], proxyPort)
	}
}

func TestBuildXrayBridgeConfigPreservesHTTPUpgradeSettings(t *testing.T) {
	result := BuildXrayBridgeConfig([]ProxyConfig{
		{
			Type:        "vless",
			Tag:         "httpupgrade-test",
			Name:        "httpupgrade-test",
			Server:      "edge.example",
			ServerPort:  443,
			UUID:        "11111111-1111-1111-1111-111111111111",
			Network:     "httpupgrade",
			Security:    "tls",
			SNI:         "origin.example",
			Fingerprint: "chrome",
			Host:        "upgrade.example",
			Path:        "/transport",
		},
	})

	if len(result.SingBoxProxies) != 1 || result.SingBoxProxies[0].Type != "socks" {
		t.Fatalf("sing-box bridge proxies = %#v, want one SOCKS proxy", result.SingBoxProxies)
	}
	outbounds, _ := result.XrayConfig["outbounds"].([]interface{})
	if len(outbounds) < 1 {
		t.Fatalf("xray outbounds = %#v, want VLESS outbound", result.XrayConfig["outbounds"])
	}
	outbound, _ := outbounds[0].(map[string]interface{})
	stream, _ := outbound["streamSettings"].(map[string]interface{})
	if got := stream["network"]; got != "httpupgrade" {
		t.Fatalf("xray network = %#v, want httpupgrade", got)
	}
	settings, _ := stream["httpupgradeSettings"].(map[string]interface{})
	if got := settings["host"]; got != "upgrade.example" {
		t.Fatalf("xray HTTPUpgrade host = %#v, want upgrade.example", got)
	}
	if got := settings["path"]; got != "/transport" {
		t.Fatalf("xray HTTPUpgrade path = %#v, want /transport", got)
	}
	tlsSettings, _ := stream["tlsSettings"].(map[string]interface{})
	if got := tlsSettings["serverName"]; got != "origin.example" {
		t.Fatalf("xray TLS serverName = %#v, want origin.example", got)
	}
	if got := tlsSettings["fingerprint"]; got != "chrome" {
		t.Fatalf("xray TLS fingerprint = %#v, want chrome", got)
	}
	if mux, exists := outbound["mux"]; exists {
		t.Fatalf("xray HTTPUpgrade unexpectedly enables mux: %#v", mux)
	}
}
