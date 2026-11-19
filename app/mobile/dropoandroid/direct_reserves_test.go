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
	if err := CheckConfig(runtime.Config); err != nil {
		t.Fatal("pinned Play runtime rejected a direct reserve", err)
	}
}
