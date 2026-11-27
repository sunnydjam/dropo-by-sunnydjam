// Package vpnpresence reports only the presence of an authenticated VPN session.
package vpnpresence

import (
	"context"
	"dropocore/dnspolicy"
	"net/http"
	"sync"
	"time"
)

type credential struct {
	origin string
	token  string
}

type Reporter struct {
	mu         sync.Mutex
	credential credential
	wake       chan struct{}
}

// SetCredential takes an existing app session token from the local UI. The
// token stays in this process and can only go to the compiled account origins.
func (r *Reporter) SetCredential(origin, token string, active func() bool) bool {
	if token != "" {
		if (origin != "https://api.droponevedimka.ru" && origin != "https://dropo.fun") || len(token) > 256 {
			return false
		}
		for _, c := range token {
			if c <= ' ' || c >= 127 {
				return false
			}
		}
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if token == "" {
		origin = ""
	}
	r.credential = credential{origin, token}
	if r.wake == nil && token != "" {
		r.wake = make(chan struct{}, 1)
		go r.start(r.wake, active)
	}
	r.wakeLocked()
	return true
}

func (r *Reporter) Wake() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.wakeLocked()
}

func (r *Reporter) wakeLocked() {
	select {
	case r.wake <- struct{}{}:
	default:
	}
}

func (r *Reporter) start(wake chan struct{}, active func() bool) {
	transport := dnspolicy.InfrastructureTransport()
	defer transport.CloseIdleConnections()
	client := &http.Client{
		Transport:     transport,
		Timeout:       5 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	r.run(wake, active, func(method string, c credential) {
		send(client, method, c)
	})
}

func (r *Reporter) run(wake chan struct{}, active func() bool, deliver func(string, credential)) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	var previous credential
	var next time.Time
	for {
		r.mu.Lock()
		current := r.credential
		r.mu.Unlock()
		if current.token == "" || !active() {
			current = credential{}
		}
		if previous != current && previous.token != "" {
			// Keep renewals and removal ordered even across a rapid reconnect or
			// token rotation. The server timeout covers crash and lost requests.
			deliver(http.MethodDelete, previous)
			next = time.Time{}
		}
		previous = current
		if current.token != "" && !time.Now().Before(next) {
			deliver(http.MethodPost, current)
			next = time.Now().Add(30 * time.Second)
		}
		r.mu.Lock()
		if r.credential.token == "" && previous.token == "" {
			r.wake = nil
			r.mu.Unlock()
			return
		}
		r.mu.Unlock()
		select {
		case <-wake:
		case <-ticker.C:
		}
	}
}

func send(client *http.Client, method string, c credential) {
	req, err := http.NewRequestWithContext(context.Background(), method, c.origin+"/v1/vpn/presence", nil)
	if err != nil {
		return
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	response, err := client.Do(req)
	if err == nil {
		response.Body.Close()
	}
}
