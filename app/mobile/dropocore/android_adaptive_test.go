package dropocore

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestAdaptiveGraphStartsOnVPNAndScopesTLSOnly(t *testing.T) {
	resetSourceTest(t)
	sourceSuccess(t, "AddVPNSource", "One", sourceTestKey)
	sourceSuccess(t, "SetRoutingMode", "blocked_only")
	current.RoutePolicies = map[string]string{"meta": "vpn"}
	var result struct {
		Config string `json:"config"`
	}
	json.Unmarshal([]byte(BuildSingBoxConfig()), &result)
	var cfg map[string]interface{}
	if json.Unmarshal([]byte(result.Config), &cfg) != nil {
		t.Fatal("invalid config")
	}
	route := cfg["route"].(map[string]interface{})
	rules := route["rules"].([]interface{})
	if route["final"] != "direct" || rules[2].(map[string]interface{})["ip_is_private"] != true {
		t.Fatal("default/private policy changed")
	}
	found := 0
	for _, raw := range rules {
		r := raw.(map[string]interface{})
		if strings.HasPrefix(""+stringValue(r["outbound"]), AndroidAdaptiveSelectorPrefix) {
			found++
			if r["outbound"] == AndroidAdaptiveSelectorPrefix+"meta" {
				t.Fatal("manual VPN overridden")
			}
			if r["network"] != "tcp" || r["protocol"] != "tls" || r["port"] != float64(443) || r["tls_record_fragment"] != true {
				t.Fatal("adaptive rule too broad")
			}
			if _, ok := r["ip_cidr"]; ok {
				t.Fatal("hostless service CIDR")
			}
		}
	}
	if found == 0 {
		t.Fatal("adaptive graph missing")
	}
	for _, raw := range cfg["outbounds"].([]interface{}) {
		o := raw.(map[string]interface{})
		if strings.HasPrefix(stringValue(o["tag"]), AndroidAdaptiveSelectorPrefix) && o["default"] != "proxy" {
			t.Fatal("bootstrap bypasses VPN")
		}
	}
}
func stringValue(v interface{}) string { s, _ := v.(string); return s }

func TestFullVPNNeverOffersOrCommitsAdaptiveDirectStrategies(t *testing.T) {
	gen := preparedSourceSession(t)
	if current.Config.RoutingMode != "all_traffic" {
		t.Fatal("fixture must use full VPN")
	}
	var result struct {
		Config string `json:"config"`
	}
	if err := json.Unmarshal([]byte(BuildSingBoxConfig()), &result); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(result.Config, AndroidAdaptiveSelectorPrefix) || strings.Contains(result.Config, "tls_record_fragment") {
		t.Fatal("full VPN contains an automatic direct service escape")
	}
	var plan struct {
		Services []androidAdaptiveService `json:"services"`
	}
	if err := json.Unmarshal([]byte(AndroidAdaptivePlan()), &plan); err != nil || len(plan.Services) != 0 {
		t.Fatal("full VPN scheduled direct service probes")
	}
	selector := &testSourceSelector{}
	if CommitAndroidAdaptive(gen, "youtube", 3, selector) || len(selector.selected) != 0 {
		t.Fatal("full VPN accepted a direct service strategy")
	}
	current.Config.RoutingMode = "blocked_only"
	if err := json.Unmarshal([]byte(AndroidAdaptivePlan()), &plan); err != nil || len(plan.Services) == 0 {
		t.Fatal("selective mode lost adaptive service selection")
	}
}

func TestAdaptiveCommitRequiresThreeAndFencesStoppedSession(t *testing.T) {
	gen := preparedSourceSession(t)
	current.Config.RoutingMode = "blocked_only"
	selector := &testSourceSelector{}
	for _, n := range []int{1, 2, 4} {
		if CommitAndroidAdaptive(gen, "youtube", n, selector) {
			t.Fatal("partial success accepted")
		}
	}
	if !CommitAndroidAdaptive(gen, "youtube", 3, selector) || !current.adaptiveActive["youtube"] {
		t.Fatal("3/3 rejected")
	}
	if current.AdaptiveCache["youtube"].Successes != 3 {
		t.Fatal("proof not cached")
	}
	if CommitAndroidAdaptive(gen, "discord", 3, selector) {
		t.Fatal("unsupported UDP/media service accepted")
	}
	current.RoutePolicies = map[string]string{"meta": "vpn"}
	if CommitAndroidAdaptive(gen, "meta", 3, selector) {
		t.Fatal("manual policy overridden")
	}
	if !CommitAndroidAdaptive(gen, "youtube", 0, selector) || current.adaptiveActive["youtube"] || selector.selected[len(selector.selected)-1] != "proxy" {
		t.Fatal("fallback did not restore VPN")
	}
	SetConnected(false)
	n := len(selector.selected)
	if CommitAndroidAdaptive(gen, "youtube", 3, selector) || len(selector.selected) != n {
		t.Fatal("stale task changed selector")
	}
}
