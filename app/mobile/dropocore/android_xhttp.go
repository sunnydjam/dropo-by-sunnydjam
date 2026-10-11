package dropocore

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
)

const androidXHTTPOutboundType = "dropo-xhttp"
const maxAndroidXHTTPExtraBytes = 16 * 1024

// AndroidXHTTPValidator is implemented by the bundled Android runtime. Import
// must use the same Xray parser as the connection path without starting an
// engine, opening sockets, or exposing configuration in errors.
type AndroidXHTTPValidator interface {
	ValidateXHTTP(outboundJSON string) bool
}

var androidXHTTPValidationMu sync.RWMutex
var androidXHTTPValidator AndroidXHTTPValidator

// RegisterAndroidXHTTPValidator enables XHTTP only when its actual runtime is
// linked. A standalone core or a second registration fails closed.
func RegisterAndroidXHTTPValidator(validator AndroidXHTTPValidator) bool {
	androidXHTTPValidationMu.Lock()
	defer androidXHTTPValidationMu.Unlock()
	if validator == nil || androidXHTTPValidator != nil {
		return false
	}
	androidXHTTPValidator = validator
	return true
}

// ValidateAndroidXHTTPExtra lets the bundled runtime apply the same bounded
// transport contract to raw cached configurations as the subscription importer.
// It performs no runtime parsing, network I/O, or validator callback.
func ValidateAndroidXHTTPExtra(extraJSON string) bool {
	_, err := parseAndroidXHTTPExtra(extraJSON)
	return err == nil
}

func isAndroidProxySupported(proxy proxyConfig) bool {
	if normalizeTransport(proxy.Network) != "xhttp" {
		return isTransportSupported(proxy.Network)
	}
	if err := validateAndroidXHTTPProxy(proxy); err != nil {
		return false
	}
	androidXHTTPValidationMu.RLock()
	validator := androidXHTTPValidator
	androidXHTTPValidationMu.RUnlock()
	if validator == nil {
		return false
	}
	data, err := json.Marshal(proxyToAndroidXrayOutbound(proxy, "dropo-xhttp-out"))
	return err == nil && validator.ValidateXHTTP(string(data))
}

func validateAndroidXHTTPProxy(proxy proxyConfig) error {
	invalid := fmt.Errorf("unsupported Android XHTTP configuration")
	if proxy.Type != "vless" || normalizeTransport(proxy.Network) != "xhttp" ||
		validateProxy(proxy) != nil || proxy.ServerPort > 65535 || len(proxy.Server) > 253 ||
		strings.ContainsAny(proxy.Server, "\x00\r\n/\\") || len(proxy.UUID) > 128 ||
		len(proxy.SNI) > 253 || len(proxy.Host) > 253 || len(proxy.Path) > 4096 ||
		strings.ContainsAny(proxy.SNI+proxy.Host+proxy.Path, "\x00\r\n") {
		return invalid
	}
	switch proxy.Security {
	case "", "none", "tls", "reality":
	default:
		return invalid
	}
	switch proxy.Mode {
	case "", "auto", "packet-up", "stream-up", "stream-one":
	default:
		return invalid
	}
	if proxy.HeaderType != "" && proxy.HeaderType != "none" {
		return invalid
	}
	if len(proxy.Fingerprint) > 64 || len(proxy.PublicKey) > 128 || len(proxy.ShortID) > 16 ||
		len(proxy.Flow) > 64 || len(proxy.ALPN) > 256 {
		return invalid
	}
	if _, err := parseAndroidXHTTPExtra(proxy.Extra); err != nil {
		return invalid
	}
	return nil
}

func proxyToAndroidXrayOutbound(proxy proxyConfig, tag string) map[string]interface{} {
	user := map[string]interface{}{"id": proxy.UUID, "encryption": "none"}
	if proxy.Flow != "" {
		user["flow"] = proxy.Flow
	}
	stream := map[string]interface{}{"network": "xhttp"}
	if proxy.Security != "" && proxy.Security != "none" {
		stream["security"] = proxy.Security
	}
	security := map[string]interface{}{}
	if proxy.SNI != "" {
		security["serverName"] = proxy.SNI
	}
	if proxy.Fingerprint != "" {
		security["fingerprint"] = proxy.Fingerprint
	}
	if alpn := splitCSV(proxy.ALPN); len(alpn) > 0 && proxy.Security == "tls" {
		security["alpn"] = alpn
	}
	switch proxy.Security {
	case "tls":
		stream["tlsSettings"] = security
	case "reality":
		security["publicKey"] = proxy.PublicKey
		if proxy.ShortID != "" {
			security["shortId"] = proxy.ShortID
		}
		stream["realitySettings"] = security
	}
	xhttp := map[string]interface{}{}
	if proxy.Path != "" {
		xhttp["path"] = proxy.Path
	}
	if proxy.Host != "" {
		xhttp["host"] = proxy.Host
	}
	if proxy.Mode != "" {
		xhttp["mode"] = proxy.Mode
	}
	if extra, err := parseAndroidXHTTPExtra(proxy.Extra); err == nil && extra != nil {
		if download, ok := extra["downloadSettings"].(map[string]interface{}); ok {
			// Xray accepts both names, but the Android runtime consumes one
			// canonical contract so import and connection validation agree.
			download["network"] = "xhttp"
			if split, exists := download["splithttpSettings"]; exists {
				download["xhttpSettings"] = split
				delete(download, "splithttpSettings")
			}
		}
		xhttp["extra"] = extra
	}
	stream["xhttpSettings"] = xhttp
	return map[string]interface{}{
		"tag": tag, "protocol": "vless", "settings": map[string]interface{}{
			"vnext": []interface{}{map[string]interface{}{
				"address": proxy.Server, "port": proxy.ServerPort, "users": []interface{}{user},
			}},
		}, "streamSettings": stream,
	}
}

// Extra is transport data, never an arbitrary Xray configuration. In
// particular it cannot introduce file reads, custom dialers, socket marks,
// alternate protocols, server-side settings, or nested unbounded extras.
func parseAndroidXHTTPExtra(raw string) (map[string]interface{}, error) {
	invalid := fmt.Errorf("invalid Android XHTTP extra settings")
	if len(raw) > maxAndroidXHTTPExtraBytes {
		return nil, invalid
	}
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}
	decoder := json.NewDecoder(bytes.NewBufferString(raw))
	decoder.UseNumber()
	var extra map[string]interface{}
	if decoder.Decode(&extra) != nil || extra == nil {
		return nil, invalid
	}
	// Reject a second JSON value rather than accepting a truncated object.
	var remainder interface{}
	if decoder.Decode(&remainder) != io.EOF {
		return nil, invalid
	}
	if !validAndroidXHTTPSettings(extra, false) {
		return nil, invalid
	}
	return extra, nil
}

func validAndroidXHTTPSettings(settings map[string]interface{}, nested bool) bool {
	if len(settings) > 40 {
		return false
	}
	for key, value := range settings {
		switch key {
		case "host", "path", "mode", "xPaddingKey", "xPaddingHeader", "xPaddingPlacement", "xPaddingMethod",
			"uplinkHTTPMethod", "sessionPlacement", "sessionKey", "seqPlacement", "seqKey", "uplinkDataPlacement", "uplinkDataKey":
			text, ok := value.(string)
			if !ok || len(text) > 4096 || !validAndroidXHTTPHeader("X", text) {
				return false
			}
			if text != "" && (key == "xPaddingHeader" ||
				key == "sessionKey" && settings["sessionPlacement"] == "header" ||
				key == "seqKey" && settings["seqPlacement"] == "header" ||
				key == "uplinkDataKey" && settings["uplinkDataPlacement"] == "header") &&
				!validAndroidXHTTPHeader(text, "") {
				return false
			}
		case "xPaddingObfsMode", "noGRPCHeader", "noSSEHeader":
			if _, ok := value.(bool); !ok {
				return false
			}
		case "headers":
			headers, ok := value.(map[string]interface{})
			if !ok || len(headers) > 32 {
				return false
			}
			for header, raw := range headers {
				text, ok := raw.(string)
				if !ok || header == "" || strings.EqualFold(header, "host") || len(header) > 128 ||
					len(text) > 2048 || !validAndroidXHTTPHeader(header, text) {
					return false
				}
			}
		case "xPaddingBytes":
			if !boundedAndroidXHTTPRange(value, 1, 8192) {
				return false
			}
		case "scMaxEachPostBytes":
			if !boundedAndroidXHTTPRange(value, 1, 4*1024*1024) {
				return false
			}
		case "scMinPostsIntervalMs":
			if !boundedAndroidXHTTPRange(value, 0, 60000) {
				return false
			}
		case "scStreamUpServerSecs":
			if !boundedAndroidXHTTPRange(value, 0, 3600) {
				return false
			}
		case "uplinkChunkSize":
			if !boundedAndroidXHTTPRange(value, 1, 64*1024) {
				return false
			}
		case "scMaxBufferedPosts":
			if !boundedAndroidXHTTPRange(value, 0, 256) {
				return false
			}
		case "scMaxConcurrentPosts":
			// Kept as provider transport data for older XHTTP subscriptions;
			// newer Xray versions may ignore this retired setting.
			if !boundedAndroidXHTTPRange(value, 0, 128) {
				return false
			}
		case "serverMaxHeaderBytes":
			if !boundedAndroidXHTTPRange(value, 0, 1024*1024) {
				return false
			}
		case "xmux":
			xmux, ok := value.(map[string]interface{})
			if !ok || len(xmux) > 6 {
				return false
			}
			for option, rangeValue := range xmux {
				maximum := int64(100000)
				switch option {
				case "maxConcurrency":
					maximum = 128
				case "maxConnections":
					maximum = 16
				case "cMaxReuseTimes", "hMaxRequestTimes":
				case "hMaxReusableSecs":
					maximum = 86400
				case "hKeepAlivePeriod":
					maximum = 3600
				default:
					return false
				}
				if !boundedAndroidXHTTPRange(rangeValue, 0, maximum) {
					return false
				}
			}
		case "downloadSettings":
			if nested || !validAndroidXHTTPDownloadSettings(value) {
				return false
			}
		default:
			return false
		}
	}
	return true
}

func validAndroidXHTTPHeader(name, value string) bool {
	for i := 0; i < len(name); i++ {
		c := name[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
			strings.ContainsRune("!#$%&'*+-.^_`|~", rune(c)) {
			continue
		}
		return false
	}
	for i := 0; i < len(value); i++ {
		c := value[i]
		if (c < 32 && c != '\t') || c == 127 {
			return false
		}
	}
	return name != ""
}

func boundedAndroidXHTTPRange(value interface{}, minimum, maximum int64) bool {
	var text string
	switch v := value.(type) {
	case json.Number:
		text = v.String()
	case string:
		text = v
	default:
		return false
	}
	parts := strings.Split(text, "-")
	if len(parts) < 1 || len(parts) > 2 {
		return false
	}
	previous := minimum
	for _, part := range parts {
		number, err := strconv.ParseInt(part, 10, 64)
		if err != nil || number < previous || number > maximum {
			return false
		}
		previous = number
	}
	return true
}

func validAndroidXHTTPDownloadSettings(value interface{}) bool {
	settings, ok := value.(map[string]interface{})
	if !ok || len(settings) > 7 {
		return false
	}
	address, addressOK := settings["address"].(string)
	network, networkOK := settings["network"].(string)
	if !addressOK || address == "" || len(address) > 253 || strings.ContainsAny(address, "\x00\r\n/\\") ||
		!networkOK || normalizeTransport(network) != "xhttp" || !boundedAndroidXHTTPRange(settings["port"], 1, 65535) {
		return false
	}
	// A colon is permitted only for an IPv6 address, not a URL or host:port.
	if strings.Contains(address, ":") && net.ParseIP(address) == nil {
		return false
	}
	for key, field := range settings {
		switch key {
		case "address", "port", "network":
		case "security":
			security, ok := field.(string)
			if !ok || (security != "" && security != "none" && security != "tls" && security != "reality") {
				return false
			}
		case "tlsSettings", "realitySettings":
			security, ok := field.(map[string]interface{})
			if !ok || len(security) > 5 {
				return false
			}
			for option, raw := range security {
				switch option {
				case "serverName", "fingerprint":
				case "publicKey", "shortId", "spiderX":
					if key != "realitySettings" {
						return false
					}
				case "alpn":
					items, ok := raw.([]interface{})
					if !ok || key != "tlsSettings" || len(items) > 8 {
						return false
					}
					for _, item := range items {
						if text, ok := item.(string); !ok || len(text) > 64 || strings.ContainsAny(text, "\x00\r\n") {
							return false
						}
					}
					continue
				default:
					return false
				}
				if text, ok := raw.(string); !ok || len(text) > 253 || strings.ContainsAny(text, "\x00\r\n") {
					return false
				}
			}
		case "xhttpSettings", "splithttpSettings":
			xhttp, ok := field.(map[string]interface{})
			if !ok || !validAndroidXHTTPSettings(xhttp, true) {
				return false
			}
		default:
			return false
		}
	}
	_, hasXHTTP := settings["xhttpSettings"]
	_, hasSplitHTTP := settings["splithttpSettings"]
	return hasXHTTP != hasSplitHTTP
}
