package main

import "runtime"

func (a *App) SetVPNPresenceCredential(origin, token string) map[string]interface{} {
	return map[string]interface{}{"success": runtime.GOOS == "windows" &&
		a.vpnPresence.SetCredential(origin, token, a.vpnPresenceActive)}
}

func (a *App) vpnPresenceActive() bool {
	a.mu.Lock()
	running := a.isRunning && !a.isStarting
	a.mu.Unlock()
	if !running || a.vpnStopping.Load() {
		return false
	}
	known, available, _ := a.vpnSourceAvailabilitySnapshot()
	return known && available
}
