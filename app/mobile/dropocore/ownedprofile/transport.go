package ownedprofile

import "strings"

// ApplyXHTTPBudget bounds the managed ingress's H2 carriers per pool. Bursts
// of independent carriers caused stalls in repeated native-client acceptance.
// Other providers retain their own transport settings and concurrency policy.
func ApplyXHTTPBudget(server string, port int, security, sni, host string, settings map[string]interface{}) bool {
	path, _ := settings["path"].(string)
	path = strings.TrimSuffix(path, "/")
	primary := (server == PrimaryIPv4 || server == legacyPrimaryIPv4 || server == primaryHostname) && sni == primaryHostname && host == primaryHostname
	reserve := server == ReserveIPv4 && sni == ReserveHostname && host == ReserveHostname
	if (!primary && !reserve) || port != 443 || security != "tls" || (path != "/managed/v1/free" && path != "/managed/v1/boost") {
		return false
	}
	extra, _ := settings["extra"].(map[string]interface{})
	if extra == nil {
		extra = map[string]interface{}{}
		settings["extra"] = extra
	}
	// Xray's extra object replaces the root options, so put the budget there.
	extra["xmux"] = map[string]interface{}{"maxConnections": 1, "maxConcurrency": 0, "hMaxRequestTimes": "600-900", "hMaxReusableSecs": "1800-3000"}
	return true
}
