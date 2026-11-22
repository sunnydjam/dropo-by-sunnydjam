package ownedprofile

import (
	"crypto/sha256"
	"dropocore/dnspolicy"
	"encoding/base64"
	"encoding/hex"
	"net"
	"net/url"
	"strings"
	"time"
)

// These identify Dropo's dedicated REALITY ingress, not a user credential.
const finlandPublicKey = "TB8FIOdQ6nJc4M4pKScvt6isIN97rwcBjwzzhWSSPjs"
const finlandShortID = "156fc43012055390"

func IsFinlandReserveID(id string) bool {
	return id == Free+"-fi-tcp" || id == Boost+"-fi-tcp"
}

// IsFinlandReality identifies the managed endpoint whose server requires the
// REALITY handshake supported by our pinned Xray client.
func IsFinlandReality(server string, port int, network, security, sni, key, shortID, fingerprint string) bool {
	return server == ReserveIPv4 && port == 2444 && network == "tcp" &&
		security == "reality" && sni == dnspolicy.FinlandHostname && key == finlandPublicKey && shortID == finlandShortID && fingerprint == "chrome"
}

type DirectReserve struct {
	FinlandRelayURI string
	ID              string
	Name            string
	URI             string
}

type Source struct {
	ID, Provider, URI string
	Disabled          bool
}

// DirectReserves adds one candidate per independent ingress. The protected
// primary is authoritative for lifetime and identity; arbitrary keys never
// acquire an owned reserve and no client sends a primary UUID to FI or LV.
func DirectReserves(id, raw string, now time.Time) []DirectReserve {
	if !IsPrimary(id) || Expired(id, raw, now) {
		return nil
	}
	primary, _ := url.Parse(raw)
	key := strings.ToLower(primary.User.Username())
	if id == Free {
		hash := scopedKey("lv1", key)
		name := RegionName(id)
		lv := url.URL{Scheme: "hysteria2", User: url.User(base64.RawURLEncoding.EncodeToString(hash[:])), Host: net.JoinHostPort(dnspolicy.LatviaIPv4, "2443"), Fragment: name,
			RawQuery: url.Values{"sni": {dnspolicy.LatviaHostname}, "alpn": {"h3"}}.Encode()}
		return []DirectReserve{{ID: id + "-lv-quic", Name: name, URI: lv.String()}}
	}
	_, relayURI, err := Pair(id, raw)
	if err != nil {
		return nil
	}
	name := RegionName(id)
	fi := url.URL{Scheme: "vless", User: url.User(finlandUUID(key)), Host: net.JoinHostPort(ReserveIPv4, "2444"), Fragment: name,
		RawQuery: url.Values{"security": {"reality"}, "sni": {dnspolicy.FinlandHostname}, "type": {"tcp"}, "encryption": {"none"}, "fp": {"chrome"}, "pbk": {finlandPublicKey}, "sid": {finlandShortID}}.Encode()}
	return []DirectReserve{{ID: id + "-fi-tcp", Name: name, URI: fi.String(), FinlandRelayURI: relayURI}}
}

func RegionName(id string) string {
	switch id {
	case Free:
		return "Dropo Free · Латвия"
	case Boost:
		return "Dropo Boost · Финляндия"
	default:
		return ""
	}
}

func scopedKey(node, primary string) [32]byte {
	return sha256.Sum256([]byte("dropo-direct-reserve-v1\x00" + node + "\x00" + primary))
}

func finlandUUID(key string) string {
	hash := scopedKey("fi1", key)
	hash[6] = hash[6]&0x0f | 0x40
	hash[8] = hash[8]&0x3f | 0x80
	value := hex.EncodeToString(hash[:16])
	return value[:8] + "-" + value[8:12] + "-" + value[12:16] + "-" + value[16:20] + "-" + value[20:32]
}

// FinlandQUICCarrier uses the paying subscriber's independent Latvian key.
// The second hop still authenticates to the Finnish Boost server.
func FinlandQUICCarrier(raw, uuid, tag string) (map[string]any, bool) {
	return finlandQUICCarrier(Boost, raw, uuid, tag)
}

// FinlandRelayQUICCarrier reconstructs the same first hop from the validated
// Boost relay credential already carried by Android's prepared plan.
func FinlandRelayQUICCarrier(raw, uuid, tag string) (map[string]any, bool) {
	return finlandQUICCarrier(BoostReserve, raw, uuid, tag)
}

func finlandQUICCarrier(provider, raw, uuid, tag string) (map[string]any, bool) {
	if Expired(provider, raw, time.Now()) {
		return nil, false
	}
	u, _ := url.Parse(raw)
	key := strings.ToLower(u.User.Username())
	if finlandUUID(key) != uuid {
		return nil, false
	}
	scoped := scopedKey("lv1", key)
	return map[string]any{
		"tag": tag, "protocol": "hysteria",
		"settings": map[string]any{"version": 2, "address": dnspolicy.LatviaIPv4, "port": 2444},
		"streamSettings": map[string]any{"network": "hysteria", "security": "tls",
			"tlsSettings":      map[string]any{"serverName": dnspolicy.LatviaHostname, "alpn": []string{"h3"}},
			"hysteriaSettings": map[string]any{"version": 2, "auth": base64.RawURLEncoding.EncodeToString(scoped[:])},
		},
	}, true
}

// FinlandRelayOutbound constructs only the operator's authenticated HTTPS first hop.
// The Finnish credential must belong to the same subscription and tier.
func FinlandRelayOutbound(raw, uuid string, port int, tag string) (map[string]any, bool) {
	if port != 2444 || Expired(BoostReserve, raw, time.Now()) {
		return nil, false
	}
	u, err := url.Parse(raw)
	if err != nil || u.User == nil || finlandUUID(strings.ToLower(u.User.Username())) != uuid {
		return nil, false
	}
	httpSettings := map[string]any{"host": ReserveHostname, "path": "/managed/v1/boost", "mode": "auto"}
	ApplyXHTTPBudget(ReserveIPv4, 443, "tls", ReserveHostname, ReserveHostname, httpSettings)
	return map[string]any{
		"tag": tag, "protocol": "vless",
		"settings":       map[string]any{"vnext": []any{map[string]any{"address": ReserveIPv4, "port": 443, "users": []any{map[string]any{"id": u.User.Username(), "encryption": "none"}}}}},
		"streamSettings": map[string]any{"network": "xhttp", "security": "tls", "tlsSettings": map[string]any{"serverName": ReserveHostname, "fingerprint": "chrome", "alpn": []any{"h2"}}, "xhttpSettings": httpSettings},
	}, true
}
