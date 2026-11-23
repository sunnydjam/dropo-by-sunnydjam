package ownedprofile

import (
	"crypto/sha256"
	"dropocore/dnspolicy"
	"encoding/base64"
	"encoding/hex"
	"net"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// These identify Dropo's dedicated REALITY ingress, not a user credential.
const finlandPublicKey = "TB8FIOdQ6nJc4M4pKScvt6isIN97rwcBjwzzhWSSPjs"
const finlandShortID = "156fc43012055390"
const latviaRealityName = "api.droponevedimka.in"
const latviaPublicKey = "J26jwaXFR_4DrAswgMXV0Z-ME_c6HJc543f06CridSM"
const latviaShortID = "3613ced3f53e2f97"
const finlandTLSName = "fi1.dropo.fun"

const (
	Hysteria    = "hysteria2"
	Reality     = "tcp"
	XHTTP       = "xhttp"
	ExtraSuffix = "-regional-extra"
)

func IsFinlandReserveID(id string) bool {
	return id == Free+"-fi-tcp" || id == Boost+"-fi-tcp"
}

type regionalEndpoint struct {
	ip, tlsName, realityName, realityKey, shortID string
	port                                          int
}

func regionalEndpointFor(provider string) regionalEndpoint {
	if provider == Free {
		return regionalEndpoint{dnspolicy.LatviaIPv4, dnspolicy.LatviaHostname, latviaRealityName, latviaPublicKey, latviaShortID, 2443}
	}
	return regionalEndpoint{dnspolicy.FinlandIPv4, finlandTLSName, dnspolicy.FinlandHostname, finlandPublicKey, finlandShortID, 2444}
}

// IsManagedReality recognizes the exact regional socket and public identity.
func IsManagedReality(server string, port int, network, security, sni, key, shortID, fingerprint string) bool {
	if network != "tcp" || security != "reality" || fingerprint != "chrome" {
		return false
	}
	for _, tier := range []string{Free, Boost} {
		e := regionalEndpointFor(tier)
		if server == e.ip && port == e.port && sni == e.realityName && key == e.realityKey && shortID == e.shortID {
			return true
		}
	}
	return false
}

type DirectReserve struct {
	ID, Name, URI, Ingress string
}

type Source struct {
	ID, Provider, URI string
	Disabled          bool
	ManagedIngress    string
}

func ValidIngress(id, ingress string) bool {
	return IsPrimary(id) && (ingress == "" || ingress == Hysteria || ingress == Reality || ingress == XHTTP)
}

func NormalizeIngress(id, ingress string) string {
	if !IsPrimary(id) {
		return ""
	}
	switch {
	case ingress == "main":
		return XHTTP
	case ingress == "latvia" && id == Free:
		return Hysteria
	case ingress == "finland" && id == Boost:
		return Reality
	case ValidIngress(id, ingress):
		return ingress
	default:
		return ""
	}
}

// The first method only assigns the legacy tag ID. Session probes determine
// priority independently of the order used when building the config.
func RegionalIngress(id string) string {
	if id == Free {
		return Hysteria
	}
	if id == Boost {
		return Reality
	}
	return ""
}

func ExtraIngress(id string) string {
	if id == Free {
		return Reality
	}
	return Hysteria
}

func CandidateIngress(provider, candidate string) string {
	switch candidate {
	case provider + "-lv-quic":
		if provider == Free {
			return Hysteria
		}
	case provider + "-fi-tcp":
		if provider == Boost {
			return Reality
		}
	case provider + MainSuffix:
		return XHTTP
	case provider + ExtraSuffix:
		return ExtraIngress(provider)
	}
	return ""
}

func DirectReserves(id, raw string, now time.Time) []DirectReserve {
	if !IsPrimary(id) || Expired(id, raw, now) {
		return nil
	}
	primary, _ := url.Parse(raw)
	key := strings.ToLower(primary.User.Username())
	e := regionalEndpointFor(id)
	port := strconv.Itoa(e.port)
	tcpID, quicID, pool := id+ExtraSuffix, id+"-lv-quic", "free"
	var uuid, auth string
	if id == Free {
		lv := scopedKey("lv1", key)
		auth = base64.RawURLEncoding.EncodeToString(lv[:])
		uuid = keyUUID(regionalKey("vless", auth))
	} else {
		tcpID, quicID, pool = id+"-fi-tcp", id+ExtraSuffix, "boost"
		uuid = keyUUID(scopedKey("fi1", key))
		fi := regionalKey("hysteria2", uuid)
		auth = base64.RawURLEncoding.EncodeToString(fi[:])
	}

	name := RegionName(id)
	quic := url.URL{Scheme: "hysteria2", User: url.User(auth), Host: net.JoinHostPort(e.ip, port),
		Fragment: name + " · Hysteria 2", RawQuery: url.Values{"sni": {e.tlsName}, "alpn": {"h3"}}.Encode()}
	tcp := url.URL{Scheme: "vless", User: url.User(uuid), Host: net.JoinHostPort(e.ip, port),
		Fragment: name + " · TCP/REALITY",
		RawQuery: url.Values{"security": {"reality"}, "sni": {e.realityName}, "type": {"tcp"}, "encryption": {"none"},
			"fp": {"chrome"}, "pbk": {e.realityKey}, "sid": {e.shortID}}.Encode()}
	xhttp := url.URL{Scheme: "vless", User: url.User(uuid), Host: net.JoinHostPort(e.ip, "2446"),
		Fragment: name + " · XHTTP", RawQuery: url.Values{"security": {"tls"}, "sni": {e.tlsName}, "host": {e.tlsName},
			"type": {"xhttp"}, "encryption": {"none"}, "path": {"/managed/v1/" + pool}, "mode": {"auto"},
			"alpn": {"h2"}, "fp": {"chrome"}}.Encode()}
	hysteria := DirectReserve{ID: quicID, Name: quic.Fragment, URI: quic.String(), Ingress: Hysteria}
	reality := DirectReserve{ID: tcpID, Name: tcp.Fragment, URI: tcp.String(), Ingress: Reality}
	routes := []DirectReserve{hysteria, {ID: id + MainSuffix, Name: xhttp.Fragment, URI: xhttp.String(), Ingress: XHTTP}, reality}
	if id == Boost {
		routes[0], routes[2] = routes[2], routes[0]
	}
	return routes
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

func regionalKey(transport, key string) [32]byte {
	return sha256.Sum256([]byte("dropo-regional-v1\x00" + transport + "\x00" + key))
}

func keyUUID(hash [32]byte) string {
	hash[6] = hash[6]&0x0f | 0x40
	hash[8] = hash[8]&0x3f | 0x80
	value := hex.EncodeToString(hash[:16])
	return value[:8] + "-" + value[8:12] + "-" + value[12:16] + "-" + value[16:20] + "-" + value[20:32]
}
