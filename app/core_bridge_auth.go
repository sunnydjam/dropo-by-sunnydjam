package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// bridgeAuthHeader is the header the Flutter frontend sends with mutating
// requests. Read-only GET endpoints (status/info/logs/events) are intentionally
// unauthenticated so reachability probing and polling keep working even if token
// provisioning hiccups; only state-changing calls (connect/disconnect/call/quit)
// are guarded.
const bridgeAuthHeader = "X-Dropo-Token"

// bridgeTokenFileName is written next to the dropo-core executable so the locally
// co-located Flutter UI can read it. It is NOT a secret against the local user —
// it defends the loopback bridge against other local processes and browser-based
// DNS-rebinding to 127.0.0.1 invoking Start/Stop/quit.
const bridgeTokenFileName = "bridge-token"

const bridgeTokenRepairInterval = time.Second

func bridgeTokenPath(dataPath string) string {
	return filepath.Join(dataPath, bridgeTokenFileName)
}

// ensureBridgeToken generates a fresh random token for this process, persists it
// (0600) next to the executable, and returns it. A new token per launch means a
// stale file from a previous run can never authorize a new process.
func ensureBridgeToken(dataPath string) (string, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	token := hex.EncodeToString(raw)
	if _, err := repairBridgeTokenFile(dataPath, token); err != nil {
		return token, err
	}
	return token, nil
}

// repairBridgeTokenFile keeps the on-disk hand-off aligned with the token held
// by the running core. The Flutter process can be recreated while the elevated
// core remains alive (window/tray recovery, Explorer restart, application
// update), so losing this small file must not permanently turn the bridge into
// a read-only API that cannot accept UI commands.
func repairBridgeTokenFile(dataPath, token string) (bool, error) {
	dataPath = filepath.Clean(strings.TrimSpace(dataPath))
	token = strings.TrimSpace(token)
	if dataPath == "." || dataPath == "" {
		return false, fmt.Errorf("bridge token data path is empty")
	}
	if token == "" {
		return false, fmt.Errorf("bridge token is empty")
	}
	if err := os.MkdirAll(dataPath, 0700); err != nil {
		return false, err
	}
	path := bridgeTokenPath(dataPath)
	if current, err := os.ReadFile(path); err == nil && strings.TrimSpace(string(current)) == token {
		return false, nil
	} else if err != nil && !os.IsNotExist(err) {
		return false, err
	}
	if err := os.WriteFile(path, []byte(token), 0600); err != nil {
		return false, err
	}
	if err := os.Chmod(path, 0600); err != nil {
		return false, err
	}
	return true, nil
}

// maintainBridgeTokenFile repairs accidental deletion or replacement without
// weakening endpoint authentication. The expected in-memory token never
// changes during the core process lifetime.
func maintainBridgeTokenFile(ctx context.Context, dataPath, token string, logf func(string)) {
	ticker := time.NewTicker(bridgeTokenRepairInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			repaired, err := repairBridgeTokenFile(dataPath, token)
			if err != nil {
				if logf != nil {
					logf("[BridgeAuth] token repair failed: " + err.Error())
				}
				continue
			}
			if repaired && logf != nil {
				logf("[BridgeAuth] restored missing or stale UI token")
			}
		}
	}
}

// removeBridgeToken deletes the token file on shutdown so a dangling secret does
// not linger after the bridge is gone.
func removeBridgeToken(dataPath string) {
	_ = os.Remove(bridgeTokenPath(dataPath))
}

// bridgeTokenAuthorized reports whether a request carries the expected token.
// Authentication is fail-closed: an empty expected token never authorizes a
// privileged request.
func bridgeTokenAuthorized(r *http.Request, expected string) bool {
	if expected == "" {
		return false
	}
	got := strings.TrimSpace(r.Header.Get(bridgeAuthHeader))
	if got == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(expected)) == 1
}
