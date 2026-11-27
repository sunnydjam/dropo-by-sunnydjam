package dropocore

import "dropocore/vpnpresence"

var androidVPNPresence vpnpresence.Reporter

func androidVPNPresenceActive() bool {
	mu.Lock()
	defer mu.Unlock()
	return current.Connected && androidSourceResponseLocked(current.activeSourceID).State == "ok"
}
