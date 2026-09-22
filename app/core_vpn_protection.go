package main

import "runtime"

type VPNProtectionScope string

const (
	VPNProtectionScopeDevice      VPNProtectionScope = "device"
	VPNProtectionScopeVPNServices VPNProtectionScope = "vpn_services"
)

// VPNProtectionStatus describes an independently enforced network block, not
// merely a healthy VPN process or a scheduled reconnect. It must never report
// Active until an installed guard has confirmed its live WFP filters by
// readback. Windows does not have that guard in the current runtime.
type VPNProtectionStatus struct {
	Available    bool `json:"available"`
	Active       bool `json:"active"`
	EligibleMode bool `json:"eligibleMode"`
	// TargetScope is the intended coverage for this routing mode, not evidence
	// that any traffic is currently guarded. Active is the enforcement signal.
	TargetScope VPNProtectionScope `json:"targetScope"`
	State       string             `json:"state"`
	Reason      string             `json:"reason"`
}

func currentVPNProtectionStatus(mode RoutingMode) VPNProtectionStatus {
	return vpnProtectionStatusForPlatform(mode, runtime.GOOS)
}

func vpnProtectionStatusForPlatform(mode RoutingMode, platform string) VPNProtectionStatus {
	if platform != "windows" {
		return VPNProtectionStatus{
			State:  "unsupported_platform",
			Reason: "В этом desktop runtime нет подтверждённой системной защиты трафика",
		}
	}
	if NormalizeRoutingMode(mode) != RoutingModeAllTraffic {
		return VPNProtectionStatus{
			TargetScope: VPNProtectionScopeVPNServices,
			State:       "selective_guard_not_integrated",
			Reason:      "Для выбранных сервисов нужна отдельная защита только VPN-маршрутов; общий сетевой блок нарушил бы прямые маршруты",
		}
	}
	return VPNProtectionStatus{
		EligibleMode: true,
		TargetScope:  VPNProtectionScopeDevice,
		State:        "guard_not_integrated",
		Reason:       "Автоматическое переподключение доступно, но защита всего компьютера через Windows WFP ещё не установлена",
	}
}
