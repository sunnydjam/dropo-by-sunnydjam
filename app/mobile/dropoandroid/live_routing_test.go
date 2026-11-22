package dropoandroid

import (
	"encoding/json"
	"slices"
	"testing"
)

func TestRoutingReloadBootstrapsWithTheActiveSource(t *testing.T) {
	const config = `{"outbounds":[{"tag":"proxy","outbounds":["primary","reserve","personal"],"default":"primary"}]}`
	for _, active := range []string{"primary", "reserve", "personal"} {
		next, err := keepRoutingSource(config, active)
		if err != nil {
			t.Fatal(err)
		}
		var parsed struct {
			Outbounds []struct {
				Choices []string `json:"outbounds"`
				Default string   `json:"default"`
			} `json:"outbounds"`
		}
		if json.Unmarshal([]byte(next), &parsed) != nil || len(parsed.Outbounds) != 1 ||
			parsed.Outbounds[0].Default != active ||
			!slices.Equal(parsed.Outbounds[0].Choices, []string{"primary", "reserve", "personal"}) {
			t.Fatal("reload replaced the active transport or changed fallback order")
		}
	}
	if _, err := keepRoutingSource(config, "missing"); err == nil {
		t.Fatal("reload silently replaced an active source missing from the config")
	}
}
