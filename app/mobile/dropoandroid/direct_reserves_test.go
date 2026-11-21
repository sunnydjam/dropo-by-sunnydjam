//go:build with_quic && with_utls

package dropoandroid

import (
	core "dropocore"
	"dropocore/dnspolicy"
	"dropocore/ownedprofile"
	"encoding/json"
	"github.com/xtls/xray-core/app/proxyman"
	"strings"
	"testing"
)

func TestPlayManagedDirectReservesPassPinnedEngineConfig(t *testing.T) {
	playPolicyFixture(t)
	storedCoreFixture(t)
	const fixture = "vless://11111111-2222-3333-4444-555555555555@193.233.88.97:443?type=xhttp&security=tls&sni=cdn.droponevedimka.ru&host=cdn.droponevedimka.ru&path=%2Fmanaged%2Fv1%2Ffree&encryption=none&dropo_expiry=0"
	args, _ := json.Marshal([]any{ownedprofile.Free, "Free", fixture, true})
	var enrollment struct{ Success bool }
	if json.Unmarshal([]byte(core.Call("AddManagedVPNSource", string(args))), &enrollment) != nil || !enrollment.Success {
		t.Fatal("cannot enroll the managed fixture")
	}
	paid := strings.NewReplacer("%2Ffree", "%2Fboost", "expiry=0", "expiry=4102444800").Replace(fixture)
	args, _ = json.Marshal([]any{ownedprofile.Boost, "Boost", paid, true})
	if json.Unmarshal([]byte(core.Call("AddManagedVPNSource", string(args))), &enrollment) != nil || !enrollment.Success {
		t.Fatal("Boost enrollment failed")
	}
	var runtime struct {
		Success    bool
		Config     string
		Candidates []struct{ ID string }
	}
	if json.Unmarshal([]byte(BuildSingBoxConfig()), &runtime) != nil || !runtime.Success || len(runtime.Candidates) != 2 {
		t.Fatal("expected four independent managed sources")
	}
	if !(runtime.Candidates[0].ID == ownedprofile.Free+"-lv-quic" && runtime.Candidates[1].ID == ownedprofile.Boost+"-fi-tcp" || runtime.Candidates[1].ID == ownedprofile.Free+"-lv-quic" && runtime.Candidates[0].ID == ownedprofile.Boost+"-fi-tcp") {
		t.Fatal("Latvia should bootstrap the profile with Finland available as fallback")
	}
	var graph struct{ Outbounds []map[string]any }
	if err := json.Unmarshal([]byte(runtime.Config), &graph); err != nil {
		t.Fatal(err)
	}
	var fi map[string]any
	var relay string
	for _, out := range graph.Outbounds {
		if out["tag"] == "vpn-"+ownedprofile.Boost+"-fi-tcp" && out["type"] == xhttpOutboundType {
			fi, _ = out["xray_outbound"].(map[string]any)
			relay, _ = out["finland_relay"].(string)
		}
	}
	if fi == nil {
		t.Fatal("managed Finland source did not use embedded Xray")
	}
	raw, _ := json.Marshal(fi)
	cfg, target, err := buildFinlandCarrier(raw, nil, relay)
	if relay == "" || err != nil || len(cfg.Outbound) != 1 || target != ownedprofile.ReserveIPv4+":2444" {
		t.Fatal("missing verified Finland carrier")
	}
	if _, _, err := buildFinlandCarrier(raw, nil, strings.Replace(relay, ownedprofile.ReserveIPv4, "192.0.2.10", 1)); err == nil {
		t.Fatal("accepted tampered relay URI")
	}
	fast, exit, target, err := buildFastFinlandPath(raw, nil, relay)
	if err != nil || fast == nil || exit == nil || target != dnspolicy.FinlandIPv4+":2444" {
		t.Fatal("missing full accelerated Finnish path")
	}
	sender, err := exit.Outbound[0].SenderSettings.GetInstance()
	if err != nil || sender.(*proxyman.SenderConfig).GetMultiplexSettings().GetEnabled() {
		t.Fatal("Finnish exit would discard Android session context in a mux worker")
	}
	for _, badRelay := range []string{fixture, paid, strings.Replace(relay, "11111111", "99999999", 1)} {
		if _, _, _, err := buildFastFinlandPath(raw, nil, badRelay); err == nil {
			t.Fatal("accepted unrelated carrier credential")
		}
	}
	normalized, _, err := normalizeXHTTPConfig(runtime.Config, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	var internal struct{ Outbounds []map[string]any }
	if json.Unmarshal([]byte(normalized), &internal) != nil {
		t.Fatal("invalid graph")
	}
	tag := "vpn-" + ownedprofile.Boost + "-fi-tcp"
	found := map[string]bool{}
	for _, out := range internal.Outbounds {
		switch out["tag"] {
		case tag:
			paths, _ := out["outbounds"].([]any)
			if out["type"] != "urltest" || len(paths) != 2 || paths[0] != tag+"-via-lv" || paths[1] != tag+"-via-https" {
				t.Fatal("Finnish path order or fallback changed")
			}
			found[tag] = true
		case tag + "-via-lv", tag + "-via-https":
			if out["type"] != "socks" || out["server"] != "127.0.0.1" || out["password"] == "" {
				t.Fatal("unscoped internal path")
			}
			found[out["tag"].(string)] = true
		}
	}
	if len(found) != 3 {
		t.Fatal("incomplete Finnish path graph")
	}
	stream, _ := fi["streamSettings"].(map[string]any)
	if !managedFinlandStream(fi, stream) {
		t.Fatal("missing managed TCP/REALITY stream")
	}
	for _, mutate := range []func(map[string]any){
		func(o map[string]any) { o["streamSettings"].(map[string]any)["security"] = "none" },
		func(o map[string]any) { o["streamSettings"].(map[string]any)["sockopt"] = map[string]any{} },
		func(o map[string]any) {
			o["settings"].(map[string]any)["vnext"].([]any)[0].(map[string]any)["address"] = "192.0.2.1"
		},
	} {
		var changed map[string]any
		raw, _ := json.Marshal(fi)
		if err := json.Unmarshal(raw, &changed); err != nil {
			t.Fatal(err)
		}
		mutate(changed)
		raw, _ = json.Marshal(changed)
		if _, err := buildXHTTPConfig(raw, nil); err == nil {
			t.Fatal("accepted modified managed TCP transport")
		}
		if managedFinlandStream(changed, changed["streamSettings"].(map[string]any)) {
			t.Fatal("Play accepted modified managed TCP transport")
		}
	}
	if err := CheckConfig(runtime.Config); err != nil {
		t.Fatal("pinned Play runtime rejected a direct reserve", err)
	}
}
