package dropoandroid

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strconv"
	"strings"

	core "dropocore"
	"dropocore/ownedprofile"
	_ "github.com/xtls/xray-core/app/proxyman/inbound"
	_ "github.com/xtls/xray-core/app/proxyman/outbound"
	xcore "github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf"
	_ "github.com/xtls/xray-core/proxy/vless/outbound"
	_ "github.com/xtls/xray-core/transport/internet/reality"
	_ "github.com/xtls/xray-core/transport/internet/splithttp"
	_ "github.com/xtls/xray-core/transport/internet/tcp"
	_ "github.com/xtls/xray-core/transport/internet/tls"
)

const xhttpOutboundType = "dropo-xhttp"

var errXHTTPConfig = errors.New("Android XHTTP configuration is invalid or unsupported")

type androidXHTTPValidator struct{}

func (androidXHTTPValidator) ValidateXHTTP(outboundJSON string) bool {
	_, err := buildXHTTPConfig([]byte(outboundJSON), nil)
	return err == nil
}

func init() {
	core.RegisterAndroidXHTTPValidator(androidXHTTPValidator{})
}

// Only VLESS XHTTP and the managed Finnish REALITY endpoint are accepted. No source-supplied
// inbound, file, listener, socket-option, detour, or arbitrary Xray app config
// ever reaches the embedded runtime. All failures are credential-free.
func buildXHTTPConfig(raw []byte, roots []string) (*xcore.Config, error) {
	if len(raw) == 0 || len(raw) > 64*1024 {
		return nil, errXHTTPConfig
	}
	var outbound map[string]any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	if decoder.Decode(&outbound) != nil || outbound == nil {
		return nil, errXHTTPConfig
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return nil, errXHTTPConfig
	}
	for key := range outbound {
		if key != "protocol" && key != "tag" && key != "settings" && key != "streamSettings" {
			return nil, errXHTTPConfig
		}
	}
	stream, ok := outbound["streamSettings"].(map[string]any)
	if !ok || outbound["protocol"] != "vless" {
		return nil, errXHTTPConfig
	}
	if !validateXHTTPStream(stream, 0) && !managedFinlandStream(outbound, stream) {
		return nil, errXHTTPConfig
	}
	settings, ok := outbound["settings"].(map[string]any)
	if !ok || len(settings) != 1 {
		return nil, errXHTTPConfig
	}
	servers, ok := settings["vnext"].([]any)
	if !ok || len(servers) != 1 {
		return nil, errXHTTPConfig
	}
	server, ok := servers[0].(map[string]any)
	if !ok || len(server) != 3 {
		return nil, errXHTTPConfig
	}
	address, addressOK := server["address"].(string)
	port, portOK := server["port"].(float64)
	users, usersOK := server["users"].([]any)
	if !addressOK || address == "" || len(address) > 253 || strings.ContainsAny(address, "\r\n\x00") || !portOK || port < 1 || port > 65535 || port != float64(int(port)) || !usersOK || len(users) != 1 {
		return nil, errXHTTPConfig
	}
	user, ok := users[0].(map[string]any)
	if !ok || user["encryption"] != "none" {
		return nil, errXHTTPConfig
	}
	for key := range user {
		if key != "id" && key != "encryption" && key != "flow" {
			return nil, errXHTTPConfig
		}
	}
	if flow, exists := user["flow"]; exists && flow != "" {
		return nil, errXHTTPConfig
	}
	if id, ok := user["id"].(string); !ok || id == "" || len(id) > 64 {
		return nil, errXHTTPConfig
	}
	installXHTTPRoots(stream, roots)
	// Candidate tags remain sing-box identities; the embedded instance uses
	// one stable internal outbound identity, independent of source ordering.
	outbound["tag"] = "dropo-xhttp-out"
	encoded, err := json.Marshal(outbound)
	if err != nil {
		return nil, errXHTTPConfig
	}
	var detour conf.OutboundDetourConfig
	if json.Unmarshal(encoded, &detour) != nil {
		return nil, errXHTTPConfig
	}
	config := &conf.Config{
		LogConfig:       &conf.LogConfig{LogLevel: "none", AccessLog: "none", ErrorLog: "none"},
		OutboundConfigs: []conf.OutboundDetourConfig{detour},
	}
	built, err := config.Build()
	if err != nil {
		return nil, errXHTTPConfig
	}
	return built, nil
}

// Derive an encrypted first hop only for its matching managed Finnish credential.
func buildFinlandCarrier(raw []byte, roots []string, relay string) (*xcore.Config, string, error) {
	var o map[string]any
	if json.Unmarshal(raw, &o) != nil {
		return nil, "", errXHTTPConfig
	}
	stream, _ := o["streamSettings"].(map[string]any)
	if !managedFinlandStream(o, stream) {
		return nil, "", errXHTTPConfig
	}
	server := o["settings"].(map[string]any)["vnext"].([]any)[0].(map[string]any)
	port := int(server["port"].(float64))
	users, _ := server["users"].([]any)
	if len(users) != 1 {
		return nil, "", errXHTTPConfig
	}
	user, _ := users[0].(map[string]any)
	id, _ := user["id"].(string)
	firstHop, ok := ownedprofile.FinlandRelayOutbound(relay, id, port, "dropo-fi-carrier")
	if !ok {
		return nil, "", errXHTTPConfig
	}
	encoded, err := json.Marshal(firstHop)
	if err != nil {
		return nil, "", errXHTTPConfig
	}
	config, err := buildXHTTPConfig(encoded, roots)
	return config, net.JoinHostPort(ownedprofile.ReserveIPv4, strconv.Itoa(port)), err
}

// The TCP exception accepts only the generated managed REALITY endpoint.
func managedFinlandStream(outbound, stream map[string]any) bool {
	if outbound["protocol"] != "vless" || len(stream) != 3 || stream["network"] != "tcp" || stream["security"] != "reality" {
		return false
	}
	tls, _ := stream["realitySettings"].(map[string]any)
	if len(tls) != 4 {
		return false
	}
	settings, _ := outbound["settings"].(map[string]any)
	servers, _ := settings["vnext"].([]any)
	if len(servers) != 1 {
		return false
	}
	server, _ := servers[0].(map[string]any)
	addr, _ := server["address"].(string)
	port, _ := server["port"].(float64)
	if port != 2443 && port != 2444 {
		return false
	}
	get := func(k string) string { v, _ := tls[k].(string); return v }
	return ownedprofile.IsFinlandReality(addr, int(port), "tcp", "reality", get("serverName"), get("publicKey"), get("shortId"), get("fingerprint"))
}

func validateXHTTPStream(stream map[string]any, depth int) bool {
	if depth > 2 || stream["network"] != "xhttp" {
		return false
	}
	for key := range stream {
		switch key {
		case "network", "security", "tlsSettings", "realitySettings", "xhttpSettings", "address", "port":
		default:
			return false
		}
	}
	security, _ := stream["security"].(string)
	if security != "" && security != "none" && security != "tls" && security != "reality" {
		return false
	}
	for _, name := range []string{"tlsSettings", "realitySettings"} {
		if value, exists := stream[name]; exists {
			settings, ok := value.(map[string]any)
			if !ok {
				return false
			}
			for key := range settings {
				switch key {
				case "serverName", "fingerprint", "alpn", "allowInsecure", "publicKey", "password", "shortId", "spiderX":
				default:
					return false
				}
			}
			if insecure, exists := settings["allowInsecure"]; exists && insecure != false {
				return false
			}
		}
	}
	xhttp, ok := stream["xhttpSettings"].(map[string]any)
	if !ok {
		return false
	}
	for key := range xhttp {
		if key != "host" && key != "path" && key != "mode" && key != "extra" {
			return false
		}
	}
	for key, limit := range map[string]int{"host": 253, "path": 4096, "mode": 32} {
		if value, exists := xhttp[key]; exists {
			text, ok := value.(string)
			if !ok || len(text) > limit || strings.ContainsAny(text, "\x00\r\n") {
				return false
			}
		}
	}
	if extra, exists := xhttp["extra"]; exists {
		encoded, err := json.Marshal(extra)
		if err != nil || !core.ValidateAndroidXHTTPExtra(string(encoded)) {
			return false
		}
		value, ok := extra.(map[string]any)
		if !ok {
			return false
		}
		if download, exists := value["downloadSettings"]; exists {
			settings, ok := download.(map[string]any)
			if !ok || !validateXHTTPStream(settings, depth+1) {
				return false
			}
		}
	}
	return true
}

// Android's trust store is supplied by the existing platform interface. It is
// copied into each TLS stream, including a split download, rather than relying
// on Go's Android filesystem root discovery or disabling peer verification.
func installXHTTPRoots(stream map[string]any, roots []string) {
	if len(roots) > 0 && stream["security"] == "tls" {
		settings, _ := stream["tlsSettings"].(map[string]any)
		if settings == nil {
			settings = make(map[string]any)
			stream["tlsSettings"] = settings
		}
		settings["allowInsecure"] = false
		settings["minVersion"] = "1.2"
		settings["disableSystemRoot"] = true
		certificates := make([]any, 0, len(roots))
		for _, root := range roots {
			certificates = append(certificates, map[string]any{"usage": "verify", "certificate": strings.Split(strings.TrimSpace(root), "\n")})
		}
		settings["certificates"] = certificates
	}
	if xhttp, ok := stream["xhttpSettings"].(map[string]any); ok {
		if extra, ok := xhttp["extra"].(map[string]any); ok {
			if download, ok := extra["downloadSettings"].(map[string]any); ok {
				installXHTTPRoots(download, roots)
			}
		}
	}
}
