//go:build windows

package trafficorchestrator

import (
	"errors"
	"fmt"
	"os"
	"runtime"
	"strconv"

	"github.com/go-ole/go-ole"
	"github.com/go-ole/go-ole/oleutil"
)

// The global WinDivert owner reserves these two stable firewall rule names.
const relayFirewallRulePrefix = "Dropo selective relay {13f840f4-22d6-4e11-a855-2d3f889ea786} "

func OpenSelectiveWinDivertBackend(dll, filter string, port int) (*WinDivertBackend, error) {
	if port < 1 || port > 65535 {
		return nil, errors.New("invalid relay firewall port")
	}
	b, err := OpenWinDivertBackendWithFilter(dll, filter)
	if err != nil {
		return nil, err
	}
	b.relayFirewall = true
	if err = configureRelayFirewall(port); err != nil {
		return nil, errors.Join(fmt.Errorf("configure selective relay firewall: %w", err), b.Close())
	}
	return b, nil
}

func firewallDispatch(name string) (*ole.IDispatch, error) {
	unknown, err := oleutil.CreateObject(name)
	if err != nil {
		return nil, err
	}
	defer unknown.Release()
	return unknown.QueryInterface(ole.IID_IDispatch)
}

func configureRelayFirewall(port int) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	err := ole.CoInitializeEx(0, ole.COINIT_MULTITHREADED)
	switch {
	case err == nil, oleCode(err) == 1: // S_OK or S_FALSE
		defer ole.CoUninitialize()
	case oleCode(err) == 0x80010106: // caller already owns an STA
	default:
		return err
	}
	policy, err := firewallDispatch("HNetCfg.FwPolicy2")
	if err != nil {
		return err
	}
	defer policy.Release()
	v, err := policy.GetProperty("Rules")
	if err != nil {
		return err
	}
	defer v.Clear()
	rules := v.ToIDispatch()
	if rules == nil {
		return errors.New("Windows firewall rules unavailable")
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	var cleanup error
	for _, protocol := range []int32{6, 17} {
		name := relayFirewallRulePrefix + strconv.Itoa(int(protocol))
		// Remove the previous lease before adding a port, including after a
		// process crash. Never leave a second allowed port for the same core.
		result, removeErr := rules.CallMethod("Remove", name)
		if result != nil {
			result.Clear()
		}
		if removeErr != nil && oleCode(removeErr) != 0x80070002 {
			cleanup = errors.Join(cleanup, removeErr)
			continue
		}
		if port == 0 {
			continue
		}
		if err := addRelayFirewallRule(rules, exe, name, protocol, port); err != nil {
			return err
		}
	}
	return cleanup
}

func oleCode(err error) uintptr {
	var e *ole.OleError
	if errors.As(err, &e) {
		return e.Code()
	}
	return 0
}

func addRelayFirewallRule(rules *ole.IDispatch, exe, name string, protocol int32, port int) error {
	rule, err := firewallDispatch("HNetCfg.FWRule")
	if err != nil {
		return err
	}
	defer rule.Release()
	properties := []struct {
		key   string
		value any
	}{
		{"Name", name}, {"ApplicationName", exe}, {"Protocol", protocol},
		{"LocalPorts", strconv.Itoa(port)}, {"RemoteAddresses", relayPeer4.String() + "," + relayPeer6.String()},
		{"Direction", int32(1)}, {"Action", int32(1)}, {"Profiles", int32(7)}, {"Enabled", true},
	}
	for _, property := range properties {
		result, err := rule.PutProperty(property.key, property.value)
		if result != nil {
			result.Clear()
		}
		if err != nil {
			return fmt.Errorf("firewall property %s: %w", property.key, err)
		}
	}
	result, err := rules.CallMethod("Add", rule)
	if result != nil {
		result.Clear()
	}
	return err
}
