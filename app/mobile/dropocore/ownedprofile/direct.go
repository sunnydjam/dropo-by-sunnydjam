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

type DirectReserve struct {
	ID   string
	Name string
	URI  string
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
	port := "2443"
	if id == Boost {
		port = "2444"
	}
	result := make([]DirectReserve, 0, 2)
	name := Name(id) + " · FI TCP"
	hash := scopedKey("fi1", key)
	hash[6] = hash[6]&0x0f | 0x40
	hash[8] = hash[8]&0x3f | 0x80
	value := hex.EncodeToString(hash[:16])
	uuid := value[:8] + "-" + value[8:12] + "-" + value[12:16] + "-" + value[16:20] + "-" + value[20:32]
	fi := url.URL{Scheme: "vless", User: url.User(uuid), Host: net.JoinHostPort(dnspolicy.FinlandIPv4, port), Fragment: name,
		RawQuery: url.Values{"security": {"reality"}, "sni": {dnspolicy.FinlandHostname}, "type": {"tcp"}, "encryption": {"none"}, "fp": {"chrome"}, "pbk": {finlandPublicKey}, "sid": {finlandShortID}}.Encode()}
	result = append(result, DirectReserve{ID: id + "-fi-tcp", Name: name, URI: fi.String()})
	name = Name(id) + " · LV QUIC"
	hash = scopedKey("lv1", key)
	lv := url.URL{Scheme: "hysteria2", User: url.User(base64.RawURLEncoding.EncodeToString(hash[:])), Host: net.JoinHostPort(dnspolicy.LatviaIPv4, port), Fragment: name,
		RawQuery: url.Values{"sni": {dnspolicy.LatviaHostname}, "alpn": {"h3"}}.Encode()}
	return append(result, DirectReserve{ID: id + "-lv-quic", Name: name, URI: lv.String()})
}

func scopedKey(node, primary string) [32]byte {
	return sha256.Sum256([]byte("dropo-direct-reserve-v1\x00" + node + "\x00" + primary))
}
