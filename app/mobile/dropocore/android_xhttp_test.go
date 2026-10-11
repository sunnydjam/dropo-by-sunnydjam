package dropocore

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
)

const androidXHTTPTestKey = "vless://00000000-0000-0000-0000-000000000071@xhttp.example.com:443?type=xhttp&security=tls&sni=tls.example.com&fp=chrome&path=%2Fxhttp&host=cdn.example.com&mode=auto&alpn=h2%2Chttp%2F1.1#XHTTP"
const androidXHTTPTestExtra = `{"noGRPCHeader":true,"scMaxConcurrentPosts":100,"scMaxEachPostBytes":1000000,"scMinPostsIntervalMs":30,"xPaddingBytes":"100-1000","xmux":{"maxConcurrency":16,"cMaxReuseTimes":64}}`

type testAndroidXHTTPValidator struct {
	validate func(string) bool
}

func (v testAndroidXHTTPValidator) ValidateXHTTP(config string) bool {
	if v.validate != nil {
		return v.validate(config)
	}
	var outbound map[string]interface{}
	return json.Unmarshal([]byte(config), &outbound) == nil && outbound["protocol"] == "vless"
}

func installAndroidXHTTPTestValidator(t *testing.T, validator AndroidXHTTPValidator) {
	t.Helper()
	androidXHTTPValidationMu.Lock()
	previous := androidXHTTPValidator
	androidXHTTPValidator = validator
	androidXHTTPValidationMu.Unlock()
	t.Cleanup(func() {
		androidXHTTPValidationMu.Lock()
		androidXHTTPValidator = previous
		androidXHTTPValidationMu.Unlock()
	})
}

func TestAndroidXHTTPRequiresLinkedValidatedRuntime(t *testing.T) {
	installAndroidXHTTPTestValidator(t, nil)
	if _, err := parseAndroidProxyCandidates(androidXHTTPTestKey); err == nil {
		t.Fatal("XHTTP accepted without a linked runtime")
	}
	if !RegisterAndroidXHTTPValidator(testAndroidXHTTPValidator{}) {
		t.Fatal("bundled validator could not register")
	}
	if RegisterAndroidXHTTPValidator(testAndroidXHTTPValidator{}) || RegisterAndroidXHTTPValidator(nil) {
		t.Fatal("validator registration may not be overwritten")
	}
	if _, err := parseAndroidProxyCandidates(androidXHTTPTestKey); err != nil {
		t.Fatal("validated XHTTP was not accepted")
	}
}

func TestAndroidXHTTPRuntimeParserRejectsInvalidImport(t *testing.T) {
	seen := 0
	installAndroidXHTTPTestValidator(t, testAndroidXHTTPValidator{validate: func(config string) bool {
		seen++
		if !strings.Contains(config, `"network":"xhttp"`) || !strings.Contains(config, `"protocol":"vless"`) {
			t.Error("runtime did not receive the canonical complete outbound")
		}
		return false
	}})
	if validateAndroidSubscriptionLocally(androidXHTTPTestKey) == nil || seen != 1 {
		t.Fatal("local validation did not honor runtime rejection")
	}
	if _, err := parseAndroidProxyCandidates(androidXHTTPTestKey); err == nil || seen != 2 {
		t.Fatal("subscription parser did not honor runtime rejection")
	}
}

func TestAndroidVLESSXHTTPAndSplitHTTPPreserveTransportSettings(t *testing.T) {
	installAndroidXHTTPTestValidator(t, testAndroidXHTTPValidator{})
	for _, transport := range []string{"xhttp", "splithttp"} {
		t.Run(transport, func(t *testing.T) {
			key := strings.Replace(androidXHTTPTestKey, "type=xhttp", "type="+transport, 1)
			key = strings.Replace(key, "#XHTTP", "&extra="+url.QueryEscape(androidXHTTPTestExtra)+"#XHTTP", 1)
			nodes, err := parseAndroidProxyCandidates(key)
			if err != nil || len(nodes) != 1 || nodes[0].Network != "xhttp" {
				t.Fatal("supported XHTTP alias did not parse")
			}
			outbound := proxyToSingBoxOutbound(nodes[0])
			if outbound["type"] != androidXHTTPOutboundType || outbound["tag"] != nodes[0].Tag {
				t.Fatal("XHTTP did not use the bundled-runtime placeholder")
			}
			if _, exists := outbound["server"]; exists {
				t.Fatal("XHTTP was incorrectly emitted as a native sing-box transport")
			}
			xray := outbound["xray_outbound"].(map[string]interface{})
			stream := xray["streamSettings"].(map[string]interface{})
			xhttp := stream["xhttpSettings"].(map[string]interface{})
			tls := stream["tlsSettings"].(map[string]interface{})
			if stream["network"] != "xhttp" || stream["security"] != "tls" || tls["serverName"] != "tls.example.com" ||
				tls["fingerprint"] != "chrome" || xhttp["path"] != "/xhttp" || xhttp["host"] != "cdn.example.com" || xhttp["mode"] != "auto" {
				t.Fatal("XHTTP/TLS settings changed in translation")
			}
			data, _ := json.Marshal(xhttp["extra"])
			var expected, actual interface{}
			_ = json.Unmarshal([]byte(androidXHTTPTestExtra), &expected)
			_ = json.Unmarshal(data, &actual)
			expectedData, _ := json.Marshal(expected)
			actualData, _ := json.Marshal(actual)
			if string(expectedData) != string(actualData) {
				t.Fatal("provider extra settings were not preserved")
			}
		})
	}
}

func TestAndroidXHTTPRealityAndModes(t *testing.T) {
	installAndroidXHTTPTestValidator(t, testAndroidXHTTPValidator{})
	for _, mode := range []string{"auto", "packet-up", "stream-up", "stream-one"} {
		key := strings.ReplaceAll(androidXHTTPTestKey, "mode=auto", "mode="+mode)
		key = strings.ReplaceAll(key, "security=tls", "security=reality")
		key = strings.Replace(key, "#XHTTP", "&pbk=fixture-public-key&sid=12ab#XHTTP", 1)
		nodes, err := parseAndroidProxyCandidates(key)
		if err != nil || len(nodes) != 1 {
			t.Fatal("valid XHTTP mode rejected")
		}
		xray := proxyToSingBoxOutbound(nodes[0])["xray_outbound"].(map[string]interface{})
		stream := xray["streamSettings"].(map[string]interface{})
		reality := stream["realitySettings"].(map[string]interface{})
		if stream["security"] != "reality" || reality["publicKey"] != "fixture-public-key" || reality["shortId"] != "12ab" ||
			stream["xhttpSettings"].(map[string]interface{})["mode"] != mode {
			t.Fatal("REALITY or XHTTP mode was not preserved")
		}
		if _, exists := stream["tlsSettings"]; exists {
			t.Fatal("REALITY was silently downgraded to TLS")
		}
	}
}

func TestAndroidXHTTPRejectsNonVLESSOrAmbiguousSettings(t *testing.T) {
	installAndroidXHTTPTestValidator(t, testAndroidXHTTPValidator{})
	for _, key := range []string{
		"trojan://fixture-password@example.com:443?type=xhttp&security=tls",
		strings.Replace(androidXHTTPTestKey, "mode=auto", "mode=unknown-secret", 1),
		strings.Replace(androidXHTTPTestKey, "security=tls", "security=xtls", 1),
		strings.Replace(androidXHTTPTestKey, "#XHTTP", "&mode=packet-up#XHTTP", 1),
		strings.Replace(androidXHTTPTestKey, "#XHTTP", "&encryption=unsafe-secret#XHTTP", 1),
		strings.Replace(androidXHTTPTestKey, "#XHTTP", "&headerType=http#XHTTP", 1),
		strings.Replace(androidXHTTPTestKey, "#XHTTP", "&extra=%zz-secret#XHTTP", 1),
		strings.Replace(androidXHTTPTestKey, ":443?", ":70000?", 1),
	} {
		if _, err := parseAndroidProxyCandidates(key); err == nil {
			t.Fatal("invalid Android XHTTP was accepted")
		} else if strings.Contains(err.Error(), "secret") || strings.Contains(err.Error(), "vless://") || strings.Contains(err.Error(), "fixture-password") {
			t.Fatal("XHTTP validation error leaked input")
		}
	}
}

func TestAndroidXHTTPExtraBoundsAndSafeDownloadSettings(t *testing.T) {
	for _, extra := range []string{
		androidXHTTPTestExtra,
		`{"xmux":{"maxConcurrency":"16-32","cMaxReuseTimes":0,"hMaxRequestTimes":"600-900","hMaxReusableSecs":"1800-3000"}}`,
		`{"headers":{"X-Test":"fixture"},"noSSEHeader":true}`,
		`{"downloadSettings":{"address":"download.example.com","port":443,"network":"xhttp","security":"tls","tlsSettings":{"serverName":"download.example.com","alpn":["h2"]},"xhttpSettings":{"path":"/download","host":"cdn.example.com"}}}`,
	} {
		if _, err := parseAndroidXHTTPExtra(extra); err != nil || !ValidateAndroidXHTTPExtra(extra) {
			t.Fatal("safe bounded provider extra rejected")
		}
	}
	for _, extra := range []string{
		`null`, `[]`, `{"noGRPCHeader":true} {}`, `{"noGRPCHeader":true} trailing-secret`,
		`{"sockopt":{"dialerProxy":"bypass"}}`, `{"extra":{"extra":{}}}`,
		`{"xPaddingBytes":0}`, `{"xPaddingBytes":"1000-100"}`, `{"xPaddingBytes":90000000}`,
		`{"xmux":{"maxConcurrency":100000}}`, `{"headers":{"Host":"evil.example.com"}}`,
		`{"headers":{"X-Test":"\r\nsecret"}}`, `{"noGRPCHeader":"true"}`,
		`{"headers":{"X:Bad":"fixture"}}`, `{"headers":{"X Bad":"fixture"}}`,
		`{"headers":{"X-Test":"\bcontrol"}}`,
		`{"xPaddingHeader":"X:Bad"}`, `{"sessionPlacement":"header","sessionKey":"X Bad"}`,
		`{"seqPlacement":"header","seqKey":"X:Bad"}`, `{"uplinkDataPlacement":"header","uplinkDataKey":"X Bad"}`,
		`{"downloadSettings":{"address":"download.example.com","port":443,"network":"tcp","xhttpSettings":{}}}`,
		`{"downloadSettings":{"address":"download.example.com","port":443,"network":"xhttp","tlsSettings":{"certificates":[{"certificateFile":"private-secret"}]},"xhttpSettings":{}}}`,
		`{"downloadSettings":{"port":443,"network":"xhttp","xhttpSettings":{}}}`,
		`{"downloadSettings":{"address":"download.example.com","port":443,"network":"xhttp","xhttpSettings":{"downloadSettings":{}}}}`,
		`{"headers":{"X-Test":"` + strings.Repeat("a", maxAndroidXHTTPExtraBytes) + `"}}`,
		strings.Repeat(" ", maxAndroidXHTTPExtraBytes+1),
	} {
		if _, err := parseAndroidXHTTPExtra(extra); err == nil || ValidateAndroidXHTTPExtra(extra) {
			t.Fatal("unsafe or oversized provider extra accepted")
		} else if strings.Contains(err.Error(), "secret") {
			t.Fatal("extra parse error exposed a secret")
		}
	}
}

func TestAndroidXHTTPDownloadAliasesUseCanonicalRuntimeContract(t *testing.T) {
	installAndroidXHTTPTestValidator(t, testAndroidXHTTPValidator{})
	extra := `{"downloadSettings":{"address":"download.example.com","port":443,"network":"splithttp","security":"tls","tlsSettings":{"serverName":"download.example.com"},"splithttpSettings":{"path":"/download"}}}`
	key := strings.Replace(androidXHTTPTestKey, "#XHTTP", "&extra="+url.QueryEscape(extra)+"#XHTTP", 1)
	nodes, err := parseAndroidProxyCandidates(key)
	if err != nil || len(nodes) != 1 {
		t.Fatal("bounded split-download alias rejected")
	}
	xray := proxyToSingBoxOutbound(nodes[0])["xray_outbound"].(map[string]interface{})
	stream := xray["streamSettings"].(map[string]interface{})
	generatedExtra := stream["xhttpSettings"].(map[string]interface{})["extra"].(map[string]interface{})
	download := generatedExtra["downloadSettings"].(map[string]interface{})
	if download["network"] != "xhttp" || download["xhttpSettings"].(map[string]interface{})["path"] != "/download" {
		t.Fatal("download alias did not use the canonical runtime contract")
	}
	if _, exists := download["splithttpSettings"]; exists {
		t.Fatal("uncanonicalized split-download key reached the runtime")
	}
}

func TestAndroidXHTTPHTTPSImportAddTestPersistAndCachedBuild(t *testing.T) {
	resetSourceTest(t)
	installAndroidXHTTPTestValidator(t, testAndroidXHTTPValidator{})
	key := strings.Replace(androidXHTTPTestKey, "#XHTTP", "&extra="+url.QueryEscape(androidXHTTPTestExtra)+"#XHTTP", 1)
	var requests atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		requests.Add(1)
		_, _ = w.Write([]byte(base64.StdEncoding.EncodeToString([]byte(key))))
	}))
	defer server.Close()
	installAndroidSubscriptionTestTransport(t, server.Client())
	input := server.URL + "/subscription/fixture-private-token"
	fetcher := newSubscriptionFetcher()
	fetcher.client = server.Client()
	androidSourceParser = func(uri string) ([]proxyConfig, error) {
		return parseAndroidProxyCandidatesWithFetcher(uri, fetcher)
	}
	check := sourceCall(t, "TestVPNConnection", input)
	if check["success"] != true || check["count"] != float64(1) {
		t.Fatal("XHTTP subscription test failed after successful HTTPS download")
	}
	sourceSuccess(t, "AddVPNSource", "Personal", input)
	if requests.Load() != 2 || len(current.VPNSources[0].Nodes) != 1 {
		t.Fatal("XHTTP source was not parsed and retained")
	}
	base := current.BasePath
	current = defaultState()
	EnsureStarted(base, "test")
	androidSourceParser = func(string) ([]proxyConfig, error) { return nil, fmt.Errorf("offline") }
	var result map[string]interface{}
	if json.Unmarshal([]byte(BuildSingBoxConfig()), &result) != nil || result["success"] != true || result["sourcesCached"] != true || requests.Load() != 2 {
		t.Fatal("saved XHTTP source did not build offline from private cached nodes")
	}
	var config map[string]interface{}
	_ = json.Unmarshal([]byte(result["config"].(string)), &config)
	outbounds := config["outbounds"].([]interface{})
	if outbounds[0].(map[string]interface{})["type"] != androidXHTTPOutboundType {
		t.Fatal("saved XHTTP config bypassed the actual runtime bridge")
	}
	view := Call("GetVPNSources", "[]")
	for _, secret := range []string{"fixture-private-token", "vless://", "xhttp.example.com", "tls.example.com", `"xray_outbound"`, `"extra"`} {
		if strings.Contains(view, secret) {
			t.Fatal("XHTTP source view leaked private configuration")
		}
	}
}

func TestAndroidXHTTPInvalidCachedNodeCannotCommitPartialBuild(t *testing.T) {
	resetSourceTest(t)
	installAndroidXHTTPTestValidator(t, testAndroidXHTTPValidator{})
	sourceSuccess(t, "AddVPNSource", "XHTTP", androidXHTTPTestKey)
	if !decodeSuccess(BuildSingBoxConfig()) {
		t.Fatal("valid XHTTP cache could not build")
	}
	beforeConfig := current.CachedSingBoxConfig
	beforeSignature := current.CachedConfigSignature
	beforeNode := current.preparedSources[0].NodeID
	// A corrupted or unsupported saved transport must fail before its extra
	// can be omitted by serialization or a partial plan becomes current.
	current.VPNSources[0].Nodes[0].Extra = `{"downloadSettings":{"tlsSettings":{"certificateFile":"private-fixture-secret"}}}`
	response := BuildSingBoxConfig()
	if decodeSuccess(response) || strings.Contains(response, "private-fixture-secret") {
		t.Fatal("invalid cached XHTTP was accepted or exposed")
	}
	if current.CachedSingBoxConfig != beforeConfig || current.CachedConfigSignature != beforeSignature ||
		len(current.preparedSources) != 1 || current.preparedSources[0].NodeID != beforeNode {
		t.Fatal("failed XHTTP validation committed a partial cache or source plan")
	}
}

func TestAndroidXHTTPFirstNodeAndManualChoiceRemainAuthoritative(t *testing.T) {
	resetSourceTest(t)
	installAndroidXHTTPTestValidator(t, testAndroidXHTTPValidator{})
	xhttp, err := parseAndroidProxyCandidates(androidXHTTPTestKey)
	if err != nil {
		t.Fatal(err)
	}
	ordinary, _ := parseAndroidProxyCandidates(sourceTestKey)
	androidSourceParser = func(string) ([]proxyConfig, error) { return append(xhttp, ordinary...), nil }
	sourceSuccess(t, "AddVPNSource", "Mixed", "https://example.com/sub/fixture")
	first := BuildSingBoxConfig()
	if !decodeSuccess(first) || !strings.Contains(first, "dropo-xhttp") || strings.Contains(first, `\"server\": \"example.com\"`) || len(current.preparedSources) != 1 {
		t.Fatal("source should use only its first supported authoritative node")
	}
	sourceSuccess(t, "SetVPNSourceNode", "source-1", 1)
	manual := BuildSingBoxConfig()
	if !decodeSuccess(manual) || strings.Contains(manual, "dropo-xhttp") || len(current.preparedSources) != 1 || current.preparedSources[0].NodeID != androidNodeID(ordinary[0]) {
		t.Fatal("manual ordinary node must not use the XHTTP sibling as fallback")
	}
	sourceSuccess(t, "SetVPNSourceNode", "source-1", 0)
	// Build the selected XHTTP while stopped, then verify source probe identity.
	if !decodeSuccess(BuildSingBoxConfig()) {
		t.Fatal("manual XHTTP node could not build")
	}
	SetConnected(true)
	var session map[string]interface{}
	_ = json.Unmarshal([]byte(BeginAndroidSourceSession()), &session)
	if session["success"] != true || len(session["candidates"].([]interface{})) != 1 || current.preparedSources[0].NodeID != androidNodeID(xhttp[0]) {
		t.Fatal("source probes must use the selected XHTTP candidate and bridge tag")
	}
}

func TestAndroidXHTTPDoesNotChangePrivateDirectOrServiceRouteRules(t *testing.T) {
	installAndroidXHTTPTestValidator(t, testAndroidXHTTPValidator{})
	policies := map[string]string{"youtube": androidRoutePolicyVPN, "telegram": androidRoutePolicyDirect}
	for _, routingMode := range []string{"all_traffic", "blocked_only"} {
		xhttpConfig, _, err := buildAndroidSingBoxConfig(androidXHTTPTestKey, "error", routingMode, false, "", policies)
		if err != nil {
			t.Fatal(err)
		}
		nativeConfig, _, err := buildAndroidSingBoxConfig(sourceTestKey, "error", routingMode, false, "", policies)
		if err != nil {
			t.Fatal(err)
		}
		var xhttp, native map[string]interface{}
		_ = json.Unmarshal([]byte(xhttpConfig), &xhttp)
		_ = json.Unmarshal([]byte(nativeConfig), &native)
		for _, field := range []string{"route", "dns", "inbounds"} {
			xhttpData, _ := json.Marshal(xhttp[field])
			nativeData, _ := json.Marshal(native[field])
			if string(xhttpData) != string(nativeData) {
				t.Fatal("XHTTP changed private/direct, DNS, TUN or service routing policy")
			}
		}
	}
}

func TestAndroidExistingNativeTransportGenerationUnchanged(t *testing.T) {
	installAndroidXHTTPTestValidator(t, nil)
	for transport, field := range map[string]string{"ws": "headers", "grpc": "service_name", "httpupgrade": "host"} {
		key := strings.Replace(sourceTestKey, "?security=tls#demo", "?security=tls&type="+transport+"&path=%2Fservice&host=cdn.example.com#demo", 1)
		nodes, err := parseAndroidProxyCandidates(key)
		if err != nil || len(nodes) != 1 {
			t.Fatal("existing transport rejected without XHTTP runtime")
		}
		outbound := proxyToSingBoxOutbound(nodes[0])
		if outbound["type"] != "vless" || outbound["transport"].(map[string]interface{})["type"] != transport || outbound["transport"].(map[string]interface{})[field] == nil {
			t.Fatal("existing transport changed")
		}
	}
}
