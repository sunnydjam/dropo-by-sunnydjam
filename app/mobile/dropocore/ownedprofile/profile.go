// Package ownedprofile defines individual protected Dropo source families.
package ownedprofile

import (
	"errors"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const Free = "dropo-individual-free"
const Boost = "dropo-individual-boost"
const FreeReserve = "dropo-individual-free-reserve"
const BoostReserve = "dropo-individual-boost-reserve"
const PrimaryIPv4 = "109.120.152.117"
const primaryHostname = "cdn.droponevedimka.ru"
const legacyPrimaryIPv4 = "193.233.88.97"
const MainSuffix = "-main"
const ReserveIPv4 = "91.229.239.99"
const ReserveHostname = "ms-api.ordaflow.net"

func IsPrimary(id string) bool  { return id == Free || id == Boost }
func IsReserve(id string) bool  { return id == FreeReserve || id == BoostReserve }
func IsProvider(id string) bool { return IsPrimary(id) || IsReserve(id) }
func Family(id string) string {
	switch id {
	case Free, FreeReserve:
		return Free
	case Boost, BoostReserve:
		return Boost
	default:
		return ""
	}
}
func SameFamily(a, b string) bool { return Family(a) != "" && Family(a) == Family(b) }
func Priority(id string) int {
	switch id {
	case Boost:
		return 0
	case BoostReserve:
		return 1
	case Free:
		return 2
	case FreeReserve:
		return 3
	default:
		return 4
	}
}
func Name(id string) string {
	name := "Dropo Free"
	if Family(id) == Boost {
		name = "Dropo Boost"
	}
	if IsReserve(id) {
		name += " · резерв"
	}
	return name
}

func DisplayName(id, name string) string {
	if id == Boost && (name == "" || name == Name(Boost)) {
		return "Dropo Turbo"
	}
	return name
}

// Pair only accepts a canonical owned key. It never promotes a personal source
// or accepts remote-supplied endpoints. Both entries keep one revocable key and
// lifetime, but remain independent source candidates (not subscription nodes).
func Pair(id, raw string) (string, string, error) {
	if !IsPrimary(id) {
		return "", "", errors.New("primary owned profile required")
	}
	until, err := Validate(id, raw)
	if err != nil {
		return "", "", err
	}
	u, _ := url.Parse(raw)
	reserveID := FreeReserve
	pool := "free"
	if id == Boost {
		reserveID, pool = BoostReserve, "boost"
	}
	u.Host = ReserveIPv4 + ":443"
	u.Fragment = Name(reserveID)
	u.RawQuery = url.Values{
		"type": {"xhttp"}, "security": {"tls"}, "sni": {ReserveHostname}, "host": {ReserveHostname},
		"path": {"/managed/v1/" + pool}, "mode": {"auto"}, "alpn": {"h2"}, "fp": {"chrome"},
		"encryption": {"none"}, "dropo_expiry": {strconv.FormatInt(until, 10)},
	}.Encode()
	return reserveID, u.String(), nil
}
func Validate(id, raw string) (int64, error) {
	if !IsProvider(id) || len(raw) > 4096 {
		return 0, errors.New("invalid owned profile")
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "vless" || u.User == nil || u.Path != "" || u.Opaque != "" {
		return 0, errors.New("untrusted owned ingress")
	}
	hostname := primaryHostname
	if IsReserve(id) {
		hostname = ReserveHostname
		if u.Host != ReserveIPv4+":443" {
			return 0, errors.New("untrusted owned reserve")
		}
	} else if u.Host != primaryHostname+":443" && u.Host != PrimaryIPv4+":443" && u.Host != legacyPrimaryIPv4+":443" {
		return 0, errors.New("untrusted owned ingress")
	}
	credential := u.User.Username()
	if _, set := u.User.Password(); set || !validCredential(credential) {
		return 0, errors.New("invalid owned credential")
	}
	pool := "free"
	if Family(id) == Boost {
		pool = "boost"
	}
	q, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return 0, errors.New("invalid owned query")
	}
	for key, values := range q {
		if len(values) != 1 {
			return 0, errors.New("ambiguous owned transport")
		}
		switch key {
		case "security", "sni", "host", "type", "path", "encryption", "dropo_expiry", "mode", "alpn", "fp":
		default:
			return 0, errors.New("unsupported owned transport option")
		}
	}
	if q.Get("security") != "tls" || q.Get("sni") != hostname || q.Get("host") != hostname || q.Get("type") != "xhttp" || strings.TrimSuffix(q.Get("path"), "/") != "/managed/v1/"+pool || q.Get("encryption") != "none" {
		return 0, errors.New("untrusted owned transport")
	}
	if mode := q.Get("mode"); mode != "" && mode != "auto" && mode != "packet-up" {
		return 0, errors.New("untrusted owned mode")
	}
	if alpn := q.Get("alpn"); alpn != "" && alpn != "h2" {
		return 0, errors.New("untrusted owned ALPN")
	}
	if fp := q.Get("fp"); fp != "" && fp != "chrome" {
		return 0, errors.New("untrusted owned TLS fingerprint")
	}
	if IsReserve(id) && (q.Get("alpn") != "h2" || q.Get("mode") != "auto" || q.Get("fp") != "chrome") {
		return 0, errors.New("invalid owned reserve transport")
	}
	until, err := strconv.ParseInt(q.Get("dropo_expiry"), 10, 64)
	if err != nil || until < 0 || Family(id) == Free && until != 0 || Family(id) == Boost && until == 0 {
		return 0, errors.New("invalid owned lifetime")
	}
	return until, nil
}

func Expired(id, raw string, now time.Time) bool {
	if !IsProvider(id) {
		return false
	}
	until, err := Validate(id, raw)
	return err != nil || Family(id) == Boost && until <= now.Unix()
}

func validCredential(value string) bool {
	if len(value) != 36 {
		return false
	}
	for i, c := range value {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
			continue
		}
		if !strings.ContainsRune("0123456789abcdefABCDEF", c) {
			return false
		}
	}
	return true
}
