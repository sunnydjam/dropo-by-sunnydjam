// Package ownedprofile defines the two individual, protected Dropo sources.
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

func IsProvider(id string) bool { return id == Free || id == Boost }
func Validate(id, raw string) (int64, error) {
	if !IsProvider(id) || len(raw) > 4096 {
		return 0, errors.New("invalid owned profile")
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "vless" || u.User == nil || (u.Host != "cdn.droponevedimka.ru:443" && u.Host != "193.233.88.97:443") {
		return 0, errors.New("untrusted owned ingress")
	}
	credential := u.User.Username()
	if _, set := u.User.Password(); set || len(credential) != 36 || strings.Count(credential, "-") != 4 {
		return 0, errors.New("invalid owned credential")
	}
	pool := "free"
	if id == Boost {
		pool = "boost"
	}
	q := u.Query()
	if q.Get("security") != "tls" || q.Get("sni") != "cdn.droponevedimka.ru" || q.Get("host") != "cdn.droponevedimka.ru" || q.Get("type") != "xhttp" || strings.TrimSuffix(q.Get("path"), "/") != "/managed/v1/"+pool || q.Get("encryption") != "none" {
		return 0, errors.New("untrusted owned transport")
	}
	until, err := strconv.ParseInt(q.Get("dropo_expiry"), 10, 64)
	if err != nil || until < 0 || id == Free && until != 0 || id == Boost && until == 0 {
		return 0, errors.New("invalid owned lifetime")
	}
	return until, nil
}
func Expired(id, raw string, now time.Time) bool {
	if !IsProvider(id) {
		return false
	}
	until, err := Validate(id, raw)
	return err != nil || id == Boost && until <= now.Unix()
}
