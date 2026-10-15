package dropoandroid

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"sync"
)

var errVPNEncryption = errors.New("Версия Google Play подключается только к серверам с проверяемым шифрованием VPN. Выберите сервер с TLS/REALITY или другим поддерживаемым защищённым протоколом; автоматическая замена сервера внутри подписки не выполняется.")

// The distribution is fixed by Android BuildConfig, not by saved user settings.
// An unconfigured binding fails closed and a running process cannot downgrade
// its policy by invoking a method again with another channel.
type vpnDistributionPolicy struct {
	sync.RWMutex
	configured bool
	play       bool
}

var androidVPNDistribution vpnDistributionPolicy

func (p *vpnDistributionPolicy) configure(play bool) error {
	p.Lock()
	defer p.Unlock()
	if p.configured && p.play != play {
		return errors.New("Android distribution cannot change in a running process")
	}
	p.configured, p.play = true, play
	return nil
}

func (p *vpnDistributionPolicy) requiresEncryption() bool {
	p.RLock()
	defer p.RUnlock()
	return !p.configured || p.play
}

// ConfigureDistribution is called by both the Activity and the standalone
// VpnService before loading stored state, including Android Always-on restarts.
func ConfigureDistribution(playDistribution bool) error {
	return androidVPNDistribution.configure(playDistribution)
}

func enforceVPNEncryption(config string) error {
	if !androidVPNDistribution.requiresEncryption() {
		return nil
	}
	return validateEncryptedVPNConfig(config)
}

// Validate the actual runtime graph, rather than filtering imported nodes. This
// covers old cached configurations, all independent fallback sources and the
// optional RU source without silently picking a sibling from a subscription.
// It runs before a local XHTTP bridge can replace its remote outbound.
func validateEncryptedVPNConfig(content string) error {
	if len(content) == 0 || len(content) > 4*1024*1024 {
		return errVPNEncryption
	}
	var config map[string]any
	decoder := json.NewDecoder(bytes.NewBufferString(content))
	if decoder.Decode(&config) != nil || config == nil {
		return errVPNEncryption
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return errVPNEncryption
	}
	// The current mobile builder emits no separate endpoint graph. Never let a
	// future endpoint/sidecar route bypass the audited outbound policy.
	if endpoints, exists := config["endpoints"]; exists {
		items, ok := endpoints.([]any)
		if !ok || len(items) != 0 {
			return errVPNEncryption
		}
	}
	items, ok := config["outbounds"].([]any)
	if !ok || len(items) == 0 || len(items) > 256 {
		return errVPNEncryption
	}
	tags := make(map[string]bool, len(items))
	var selectors []map[string]any
	encryptedEndpoints := 0
	for _, item := range items {
		outbound, ok := item.(map[string]any)
		tag, tagOK := outbound["tag"].(string)
		if !ok || !tagOK || tag == "" || tags[tag] {
			return errVPNEncryption
		}
		tags[tag] = true
		switch outbound["type"] {
		case "direct":
			// Direct exceptions are not VPN endpoints. Only the app's canonical
			// unmodified direct outbound is permitted, not a redirect/detour.
			if len(outbound) != 2 || tag != "direct" {
				return errVPNEncryption
			}
		case "selector":
			selectors = append(selectors, outbound)
		case "vless", "trojan", "hysteria2", "tuic":
			if !verifiedSingBoxTLS(outbound["tls"]) {
				return errVPNEncryption
			}
			encryptedEndpoints++
		case "vmess":
			security, _ := outbound["security"].(string)
			if security != "auto" && security != "aes-128-gcm" && security != "chacha20-poly1305" {
				return errVPNEncryption
			}
			if tls, exists := outbound["tls"]; exists && !verifiedSingBoxTLS(tls) {
				return errVPNEncryption
			}
			encryptedEndpoints++
		case "shadowsocks":
			if !encryptedShadowsocksMethod(outbound["method"]) {
				return errVPNEncryption
			}
			encryptedEndpoints++
		case xhttpOutboundType:
			xray, ok := outbound["xray_outbound"].(map[string]any)
			stream, streamOK := xray["streamSettings"].(map[string]any)
			if !ok || !streamOK || !verifiedXHTTPEncryption(stream, 0) {
				return errVPNEncryption
			}
			encryptedEndpoints++
		default:
			// In particular a raw SOCKS/HTTP outbound is not an encrypted VPN.
			return errVPNEncryption
		}
	}
	if encryptedEndpoints == 0 {
		return errVPNEncryption
	}
	for _, selector := range selectors {
		members, ok := selector["outbounds"].([]any)
		if !ok || len(members) == 0 {
			return errVPNEncryption
		}
		for _, member := range members {
			tag, ok := member.(string)
			if !ok || !tags[tag] || tag == "direct" || tag == selector["tag"] {
				return errVPNEncryption
			}
		}
	}
	return nil
}

func verifiedSingBoxTLS(raw any) bool {
	tls, ok := raw.(map[string]any)
	if !ok || tls["enabled"] != true {
		return false
	}
	if insecure, exists := tls["insecure"]; exists && insecure != false {
		return false
	}
	if version, exists := tls["min_version"]; exists && version != "1.2" && version != "1.3" {
		return false
	}
	if rawReality, exists := tls["reality"]; exists {
		reality, ok := rawReality.(map[string]any)
		if !ok || reality["enabled"] != true || !validRealityPublicKey(reality["public_key"]) {
			return false
		}
	}
	return true
}

func validRealityPublicKey(raw any) bool {
	value, ok := raw.(string)
	if !ok {
		return false
	}
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	return err == nil && len(decoded) == 32
}

func encryptedShadowsocksMethod(raw any) bool {
	switch raw {
	case "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
		"2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305":
		return true
	default:
		return false
	}
}

func verifiedXHTTPEncryption(stream map[string]any, depth int) bool {
	if depth > 2 || stream["network"] != "xhttp" {
		return false
	}
	security, _ := stream["security"].(string)
	var settings map[string]any
	switch security {
	case "tls":
		if raw, exists := stream["tlsSettings"]; exists {
			var ok bool
			settings, ok = raw.(map[string]any)
			if !ok {
				return false
			}
		}
		// An omitted TLS settings object uses verified runtime defaults.
	case "reality":
		settings, _ = stream["realitySettings"].(map[string]any)
		if settings == nil || !validRealityPublicKey(settings["publicKey"]) {
			return false
		}
	default:
		return false
	}
	if insecure, exists := settings["allowInsecure"]; exists && insecure != false {
		return false
	}
	xhttp, ok := stream["xhttpSettings"].(map[string]any)
	if !ok {
		return false
	}
	if rawExtra, exists := xhttp["extra"]; exists {
		extra, ok := rawExtra.(map[string]any)
		if !ok {
			return false
		}
		if rawDownload, exists := extra["downloadSettings"]; exists {
			download, ok := rawDownload.(map[string]any)
			if !ok || !verifiedXHTTPEncryption(download, depth+1) {
				return false
			}
		}
	}
	return true
}

func enforceBuiltVPNConfig(result string) string {
	if !androidVPNDistribution.requiresEncryption() {
		return result
	}
	var response struct {
		Success bool   `json:"success"`
		Config  string `json:"config"`
	}
	if json.Unmarshal([]byte(result), &response) == nil && !response.Success {
		return result
	}
	if validateEncryptedVPNConfig(response.Config) != nil {
		// Never return the offending graph, addresses or credentials in an error.
		encoded, _ := json.Marshal(map[string]any{"success": false, "error": errVPNEncryption.Error(), "code": "vpn_encryption_required"})
		return string(encoded)
	}
	return result
}
