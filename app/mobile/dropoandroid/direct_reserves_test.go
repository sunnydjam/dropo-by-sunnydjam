//go:build with_quic && with_utls

package dropoandroid

import (
	core "dropocore"
	"dropocore/ownedprofile"
	"encoding/json"
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
	var runtime struct {
		Success    bool
		Config     string
		Candidates []struct{ ID string }
	}
	if json.Unmarshal([]byte(BuildSingBoxConfig()), &runtime) != nil || !runtime.Success || len(runtime.Candidates) != 4 {
		t.Fatal("expected four independent managed sources")
	}
	for i, suffix := range []string{"-fi-tcp", "-lv-quic"} {
		if runtime.Candidates[i+2].ID != ownedprofile.Free+suffix {
			t.Fatalf("unexpected reserve candidate at %d", i+2)
		}
	}
	var graph struct{ Outbounds []map[string]any }
	if err := json.Unmarshal([]byte(runtime.Config), &graph); err != nil {
		t.Fatal(err)
	}
	var fi map[string]any
	for _, out := range graph.Outbounds {
		if out["tag"] == "vpn-"+runtime.Candidates[2].ID && out["type"] == xhttpOutboundType {
			fi, _ = out["xray_outbound"].(map[string]any)
		}
	}
	if fi == nil {
		t.Fatal("managed Finland source did not use embedded Xray")
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
