package dropocore

import (
	"dropocore/dnspolicy"
	"encoding/json"
	"strings"
	"testing"
)

const androidDNSFixture = "vless://00000000-0000-0000-0000-000000000000@203.0.113.10:443?security=tls&type=ws&sni=endpoint.example#fixture"

func decodeAndroidDNSFixture(t *testing.T, text string, err error) map[string]interface{} {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
	var config map[string]interface{}
	if err := json.Unmarshal([]byte(text), &config); err != nil {
		t.Fatal(err)
	}
	return config
}

func assertAndroidEncryptedDNSTransport(t *testing.T, config map[string]interface{}, tag string, proxy bool) {
	t.Helper()
	server := androidDNSServerByTag(config, tag)
	if server == nil || server["type"] != "https" || server["server"] != dnspolicy.BootstrapIPv4 ||
		server["server_port"] != float64(443) || server["path"] != dnspolicy.QueryPath {
		t.Fatalf("%s changed the pinned encrypted resolver: %#v", tag, server)
	}
	tls, ok := server["tls"].(map[string]interface{})
	if !ok || tls["enabled"] != true || tls["server_name"] != dnspolicy.Hostname || tls["insecure"] == true {
		t.Fatalf("%s does not verify the owned DNS hostname: %#v", tag, tls)
	}
	if proxy {
		if server["detour"] != "proxy" {
			t.Fatalf("%s still depends on direct reachability of the blocked resolver: %#v", tag, server)
		}
	} else if _, exists := server["detour"]; exists {
		t.Fatalf("%s must not depend on a VPN that is not established: %#v", tag, server)
	}
}

func assertAndroidSystemDNS(t *testing.T, config map[string]any) {
	t.Helper()
	server := androidDNSServerByTag(config, "dns-direct")
	if len(server) != 2 || server["type"] != "local" || server["tag"] != "dns-direct" {
		t.Fatalf("direct DNS is not the underlying network resolver: %#v", server)
	}
}

func TestAndroidPublicDNSUsesVPNWithoutChangingTrafficRoutes(t *testing.T) {
	for _, mode := range []string{"blocked_only", "all_traffic"} {
		t.Run(mode, func(t *testing.T) {
			text, _, err := buildAndroidSingBoxConfig(androidDNSFixture, "error", mode, false, "", map[string]string{"meta": "direct", "telegram": "vpn"})
			config := decodeAndroidDNSFixture(t, text, err)
			if mode == "blocked_only" {
				assertAndroidSystemDNS(t, config)
			} else {
				assertAndroidEncryptedDNSTransport(t, config, "dns-direct", true)
			}
			assertAndroidEncryptedDNSTransport(t, config, "dns-remote", true)
			assertAndroidEncryptedDNSTransport(t, config, "dns-bootstrap", false)

			dns := config["dns"].(map[string]interface{})
			first := dns["rules"].([]interface{})[0].(map[string]interface{})
			local := androidDNSServerByTag(config, "dns-local")
			if first["server"] != "dns-local" || local["type"] != "local" || local["detour"] != nil {
				t.Fatal("private DNS must keep the local resolver before public rules")
			}
			for _, suffix := range []string{"local", "internal", "corp", "lan", "home", "intranet", "private"} {
				if !androidContainsDNSServer(config, suffix, "dns-local") || !androidContainsDomainRoute(config, suffix, "direct") {
					t.Fatalf("private suffix %q lost local DNS or direct traffic", suffix)
				}
			}
			for _, raw := range dns["rules"].([]interface{}) {
				if raw.(map[string]interface{})["server"] == "dns-bootstrap" {
					t.Fatal("application DNS must not use the endpoint bootstrap resolver")
				}
			}
			route := config["route"].(map[string]interface{})
			private := route["rules"].([]interface{})[2].(map[string]interface{})
			if private["ip_is_private"] != true || private["outbound"] != "direct" {
				t.Fatal("private destinations must keep precedence over public VPN routes")
			}
			if route["default_domain_resolver"].(map[string]interface{})["server"] != "dns-direct" {
				t.Fatal("ordinary destination resolution bypasses the working DNS transport")
			}
			if mode == "blocked_only" {
				if dns["final"] != "dns-direct" || route["final"] != "direct" ||
					!androidContainsDNSServer(config, "gstatic.com", "dns-direct") ||
					!androidContainsDomainRoute(config, "gstatic.com", "direct") ||
					!androidContainsDomainRoute(config, "instagram.com", "direct") ||
					!androidContainsPackageRoute(config, "org.telegram.messenger", "proxy") {
					t.Fatal("tunneling DNS must not tunnel unselected traffic or override manual service routes")
				}
			} else if dns["final"] != "dns-remote" || route["final"] != "proxy" || androidContainsDomainRoute(config, "instagram.com", "direct") {
				t.Fatal("full VPN must remain authoritative over saved selective routes")
			}
		})
	}
}

func TestAndroidHostnameEndpointsBootstrapOutsideTheirOwnTunnel(t *testing.T) {
	main := strings.Replace(androidDNSFixture, "203.0.113.10", "main.example", 1)
	ru := strings.Replace(androidDNSFixture, "203.0.113.10", "ru.example", 1)
	text, _, err := buildAndroidSingBoxConfig(main, "error", "blocked_only", true, ru, nil)
	config := decodeAndroidDNSFixture(t, text, err)
	assertAndroidEncryptedDNSTransport(t, config, "dns-bootstrap", false)
	endpoints := map[string]bool{"main.example": false, "ru.example": false}
	for _, raw := range config["outbounds"].([]interface{}) {
		outbound := raw.(map[string]interface{})
		host, ok := outbound["server"].(string)
		if !ok {
			continue
		}
		resolver, ok := outbound["domain_resolver"].(map[string]interface{})
		if !ok || resolver["server"] != "dns-bootstrap" || resolver["strategy"] != "ipv4_only" {
			t.Fatalf("VPN endpoint %q would recursively resolve through its own tunnel: %#v", host, resolver)
		}
		endpoints[host] = true
	}
	if !endpoints["main.example"] || !endpoints["ru.example"] {
		t.Fatal("main or secondary hostname endpoint is missing")
	}
}

func TestAndroidDNSWithoutProxyHasNoDanglingDetour(t *testing.T) {
	outbounds, tags := buildAndroidOutbounds(nil)
	text, err := marshalAndroidSingBoxConfig(outbounds, tags, "error", "blocked_only", false, "direct", nil)
	config := decodeAndroidDNSFixture(t, text, err)
	assertAndroidSystemDNS(t, config)
	for _, tag := range []string{"dns-remote", "dns-bootstrap"} {
		assertAndroidEncryptedDNSTransport(t, config, tag, false)
	}
	if androidContainsOutbound(config, "proxy") {
		t.Fatal("fixture must exercise absence of a proxy selector")
	}
}

func TestAndroidDNSPolicyInvalidatesCachedDirectResolverConfig(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	current.Config.RoutingMode = "blocked_only"
	current.Config.AutoUpdateSub = false
	current.Subscription = androidDNSFixture
	current.CachedSingBoxConfig = `{"staleDirectDNS":true}`
	current.CachedProxyCount = 1
	current.CachedConfigSubscription = current.Subscription
	current.CachedConfigSignature = strings.Replace(
		androidConfigSignature(current.Subscription, current.Config.EnableLogging, current.Config.LogLevel, current.Config.RoutingMode, current.Config.HideRuTraffic, current.Config.RuProxyAddress, nil),
		androidConfigSchema, "android-package-routing-v12-adaptive-service-mode", 1)
	mu.Unlock()
	var response struct {
		Success bool   `json:"success"`
		Cached  bool   `json:"cached"`
		Config  string `json:"config"`
	}
	if err := json.Unmarshal([]byte(BuildSingBoxConfig()), &response); err != nil {
		t.Fatal(err)
	}
	if !response.Success || response.Cached || strings.Contains(response.Config, "staleDirectDNS") {
		t.Fatal("the previous DNS policy survived an application upgrade")
	}
	config := decodeAndroidDNSFixture(t, response.Config, nil)
	assertAndroidSystemDNS(t, config)
}
