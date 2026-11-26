package dropocore

import (
	"dropocore/aicatalog"

	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

const (
	androidRoutePolicyAuto   = "auto"
	androidRoutePolicyDirect = "direct"
	androidRoutePolicyVPN    = "vpn"
)

var androidPrimaryHomeRouteTags = map[string]bool{
	"youtube": true,
	"discord": true,
	"meta":    true,
}

type androidService struct {
	Tag            string
	Name           string
	PackageNames   []string
	DomainSuffixes []string
	IPCIDRs        []string
	HealthURL      string
	ProbeURLs      []string
}

func androidServiceCatalog() []androidService {
	services := []androidService{
		{
			Tag:  "discord",
			Name: "Discord",
			PackageNames: []string{
				"com.discord",
			},
			DomainSuffixes: []string{
				"discord.com", "discord.gg", "discordapp.com", "discordapp.net", "discord.media", "discord.gift",
				"discordcdn.com", "discordstatus.com",
			},
			IPCIDRs:   []string{"66.22.192.0/18"},
			HealthURL: "https://discord.com/api/v10/gateway",
			ProbeURLs: []string{"https://discord.com", "https://cdn.discordapp.com", "https://media.discordapp.net"},
		},
		{
			Tag:  "youtube",
			Name: "YouTube",
			DomainSuffixes: []string{
				"youtube.com", "youtu.be", "youtube-nocookie.com", "youtubeeducation.com",
				"ytimg.com", "yt3.ggpht.com", "ggpht.com", "googlevideo.com",
				"youtube-ui.l.google.com", "wide-youtube.l.google.com",
				"youtubei.googleapis.com", "youtube.googleapis.com",
				"ytstatic.com",
			},
			HealthURL: "https://www.youtube.com",
			ProbeURLs: []string{
				"https://www.youtube.com/generate_204",
				"https://youtubei.googleapis.com",
				"https://redirector.googlevideo.com",
				"https://i.ytimg.com/generate_204",
				"https://yt3.ggpht.com",
			},
		},
		{
			Tag:  "meta",
			Name: "Instagram",
			DomainSuffixes: []string{
				"instagram.com", "cdninstagram.com", "threads.net",
			},
			IPCIDRs: []string{
				"31.13.64.0/18", "66.220.144.0/20", "69.63.176.0/20", "69.171.224.0/19",
				"129.134.0.0/16", "157.240.0.0/16", "173.252.64.0/18", "185.60.216.0/22",
			},
			HealthURL: "https://www.instagram.com",
			ProbeURLs: []string{"https://www.instagram.com"},
		},
		{
			Tag:  "facebook",
			Name: "Facebook / Messenger",
			DomainSuffixes: []string{
				"facebook.com", "fbcdn.net", "fb.com", "facebook.net", "messenger.com", "m.me", "connect.facebook.net",
			},
			IPCIDRs: []string{
				"31.13.64.0/18", "66.220.144.0/20", "69.63.176.0/20", "69.171.224.0/19",
				"129.134.0.0/16", "157.240.0.0/16", "173.252.64.0/18", "185.60.216.0/22",
			},
			HealthURL: "https://www.facebook.com",
			ProbeURLs: []string{"https://connect.facebook.net"},
		},
		{
			Tag:            "twitter",
			Name:           "X (Twitter)",
			DomainSuffixes: []string{"twitter.com", "x.com", "twimg.com", "t.co", "ads-twitter.com"},
			HealthURL:      "https://x.com",
			ProbeURLs:      []string{"https://abs.twimg.com"},
		},
		{
			Tag:            "linkedin",
			Name:           "LinkedIn",
			DomainSuffixes: []string{"linkedin.com", "licdn.com", "lnkd.in", "linkedin.cn"},
			HealthURL:      "https://www.linkedin.com",
			ProbeURLs:      []string{"https://static.licdn.com"},
		},
		{
			Tag:            "signal",
			Name:           "Signal",
			DomainSuffixes: []string{"signal.org", "signal.me", "whispersystems.org", "signal.art"},
			HealthURL:      "https://signal.org",
			ProbeURLs:      []string{"https://updates.signal.org"},
		},
		{
			Tag:  "telegram",
			Name: "Telegram",
			PackageNames: []string{
				"org.telegram.messenger", "org.telegram.messenger.web", "org.thunderdog.challegram",
			},
			DomainSuffixes: []string{
				"telegram.org", "telegram.me", "t.me", "telegra.ph", "telesco.pe", "tdesktop.com",
				"telegram-cdn.org",
			},
			IPCIDRs: []string{
				"149.154.160.0/20", "91.105.192.0/23", "91.108.4.0/22", "91.108.8.0/22",
				"91.108.12.0/22", "91.108.16.0/22", "91.108.20.0/22", "91.108.56.0/22",
				"185.76.151.0/24", "2001:b28:f23d::/48", "2001:b28:f23f::/48",
				"2001:67c:4e8::/48", "2001:b28:f23c::/48", "2a0a:f280::/32",
			},
			HealthURL: "https://telegram.org",
			ProbeURLs: []string{"https://web.telegram.org", "https://t.me"},
		},
		{
			Tag:  "whatsapp",
			Name: "WhatsApp",
			DomainSuffixes: []string{
				"whatsapp.com", "whatsapp.net", "wa.me", "whatsappbrand.com",
				"cdn.whatsapp.net", "static.whatsapp.net", "scontent.whatsapp.net",
				"graph.whatsapp.com", "wa.meta.vc",
			},
			HealthURL: "https://web.whatsapp.com",
			ProbeURLs: []string{
				"https://www.whatsapp.com",
				"https://static.whatsapp.net",
				"https://graph.whatsapp.com",
			},
		},
		{
			Tag:  "facetime",
			Name: "FaceTime / iMessage",
			DomainSuffixes: []string{
				"facetime.apple.com", "ess.apple.com", "identity.apple.com",
				"push.apple.com", "init.itunes.apple.com",
			},
			HealthURL: "https://facetime.apple.com",
			ProbeURLs: []string{"https://identity.apple.com", "https://init.itunes.apple.com"},
		},
		{
			Tag:            "viber",
			Name:           "Viber",
			DomainSuffixes: []string{"viber.com", "vb.me", "viberdns.com", "viber.co", "viberapp.com"},
			HealthURL:      "https://www.viber.com",
			ProbeURLs:      []string{"https://account.viber.com"},
		},
		{
			Tag:  "snapchat",
			Name: "Snapchat",
			DomainSuffixes: []string{
				"snapchat.com", "sc-gw.com", "sc-cdn.net", "snapkit.com", "sc-static.net",
				"sc-prod.net", "sc-jpl.com", "sc-corp.net", "snapads.com", "snap.com",
				"addlive.io", "feelinsonice.com", "snapmap.com", "snapmap.org", "snapmaps.com",
			},
			HealthURL: "https://www.snapchat.com",
			ProbeURLs: []string{"https://accounts.snapchat.com", "https://app.snapchat.com"},
		},
		{
			Tag:            "twitch",
			Name:           "Twitch",
			DomainSuffixes: []string{"twitch.tv", "ttvnw.net", "jtvnw.net", "twitchcdn.net", "ext-twitch.tv"},
			HealthURL:      "https://www.twitch.tv",
			ProbeURLs:      []string{"https://static.twitchcdn.net", "https://usher.ttvnw.net"},
		},
		{
			Tag:            "spotify",
			Name:           "Spotify",
			DomainSuffixes: []string{"spotify.com", "scdn.co", "spotifycdn.com", "spoti.fi"},
			HealthURL:      "https://open.spotify.com",
			ProbeURLs:      []string{"https://api.spotify.com", "https://i.scdn.co"},
		},
		{
			Tag:  "tiktok",
			Name: "TikTok",
			DomainSuffixes: []string{
				"tiktok.com", "tiktokcdn.com", "tiktokcdn-us.com", "tiktokv.com", "tiktokv.us",
				"tiktokw.us", "ttdns2.com", "byteoversea.com", "ibyteimg.com", "ibytedtos.com",
				"ttwstatic.com",
			},
			HealthURL: "https://www.tiktok.com",
			ProbeURLs: []string{
				"https://www.tiktok.com/api/recommend/item_list/",
				"https://lf16-tiktok-web.ttwstatic.com",
			},
		},
		{
			Tag:            "canva",
			Name:           "Canva",
			DomainSuffixes: []string{"canva.com", "canva.site", "canva.design", "canva.me", "canva-apps.com"},
			HealthURL:      "https://www.canva.com",
		},
		{
			Tag:  "notion",
			Name: "Notion",
			DomainSuffixes: []string{
				"notion.com", "notion.so", "notion.site", "notion-static.com", "notionusercontent.com",
				"app.notion.com", "api.notion.com", "img.notionusercontent.com", "secure.notion-static.com",
			},
			IPCIDRs:   []string{"131.149.232.0/21", "208.103.161.0/24", "2602:F79A::/36"},
			HealthURL: "https://www.notion.com",
		},
		{
			Tag:  "slack",
			Name: "Slack",
			DomainSuffixes: []string{
				"slack.com", "slackb.com", "slack-edge.com", "slack-files.com", "slack-imgs.com",
				"slack-msgs.com", "slack-core.com", "slack-redir.net",
			},
			HealthURL: "https://slack.com",
		},
		{
			Tag:  "miro",
			Name: "Miro",
			DomainSuffixes: []string{
				"miro.com", "miro-apps.com", "mirostatic.com", "realtimeboard.com",
				"onlinewhiteboard.com", "webwhiteboard.com",
			},
			HealthURL: "https://miro.com",
		},
		{
			Tag:  "wix",
			Name: "Wix",
			DomainSuffixes: []string{
				"wix.com", "wixsite.com", "wixstatic.com", "wixmp.com", "wixapps.net",
				"editorx.com", "parastorage.com",
			},
			HealthURL: "https://www.wix.com",
		},
		{
			Tag:            "coda",
			Name:           "Coda",
			DomainSuffixes: []string{"coda.io", "codahosted.io", "codacontent.io"},
			HealthURL:      "https://coda.io",
		},
		{
			Tag:  "grammarly",
			Name: "Grammarly",
			DomainSuffixes: []string{
				"grammarly.com", "grammarly.io", "grammarly.net", "grammarlyaws.com",
			},
			HealthURL: "https://www.grammarly.com",
		},
		{
			Tag:  "docker",
			Name: "Docker Hub",
			DomainSuffixes: []string{
				"docker.com", "docker.io", "dockerhub.com", "login.docker.com", "auth.docker.com",
				"registry-1.docker.io", "auth.docker.io", "desktop.docker.com", "hub.docker.com",
				"production.cloudfront.docker.com", "production.cloudflare.docker.com",
				"docker-pinata-support.s3.amazonaws.com", "api.docker.com", "api.dso.docker.com",
				"dhi.io", "registry.scout.docker.com",
			},
			HealthURL: "https://hub.docker.com",
			ProbeURLs: []string{"https://registry-1.docker.io", "https://auth.docker.io"},
		},
		{
			Tag:  "clickup",
			Name: "ClickUp",
			DomainSuffixes: []string{
				"clickup.com", "clickup-au.com", "clickup-attachments.com", "clickup-prod.com",
				"clickup-eu.com", "clickup-sg.com", "clickup.ada.support", "codox.io",
			},
			HealthURL: "https://app.clickup.com",
			ProbeURLs: []string{"https://api.clickup.com", "https://attachments.clickup.com"},
		},
		{
			Tag:            "manychat",
			Name:           "Manychat",
			DomainSuffixes: []string{"manychat.com"},
			HealthURL:      "https://app.manychat.com",
			ProbeURLs:      []string{"https://api.manychat.com"},
		},
		{
			Tag:            "helpscout",
			Name:           "Help Scout",
			DomainSuffixes: []string{"helpscout.com", "helpscout.net", "helpscoutdocs.com"},
			HealthURL:      "https://secure.helpscout.net",
		},
		{
			Tag:  "atlassian",
			Name: "Atlassian / Trello",
			DomainSuffixes: []string{
				"atlassian.com", "atlassian.net", "atlassian.io", "atlassianstatus.com",
				"atlassianusercontent.com", "jira.com", "trello.com", "trello.services",
				"trellocdn.com", "bitbucket.org", "bitbucket.io", "bitbucketusercontent.com",
				"statuspage.io", "opsgenie.com",
			},
			HealthURL: "https://trello.com",
			ProbeURLs: []string{"https://id.atlassian.com", "https://bitbucket.org"},
		},
	}
	for _, ai := range aicatalog.Services {
		services = append(services, androidService{Tag: ai.Tag, Name: ai.Name, DomainSuffixes: ai.Domains, PackageNames: ai.Packages, HealthURL: ai.HealthURL, ProbeURLs: ai.ProbeURLs})
	}
	return services
}

func androidServiceByTag(tag string) (androidService, bool) {
	tag = strings.TrimSpace(tag)
	for _, service := range androidServiceCatalog() {
		if service.Tag == tag {
			return service, true
		}
	}
	return androidService{}, false
}

func androidServicePolicy(service androidService, policies map[string]string) string {
	if aicatalog.VPNOnly(service.Tag) {
		return androidRoutePolicyVPN
	}
	if policies != nil {
		if policy := normalizeAndroidRoutePolicy(policies[service.Tag]); policy != "" {
			return policy
		}
	}
	return androidRoutePolicyAuto
}

func normalizeAndroidRoutePolicy(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case androidRoutePolicyAuto:
		return androidRoutePolicyAuto
	case androidRoutePolicyDirect, "local":
		return androidRoutePolicyDirect
	case androidRoutePolicyVPN, "proxy", "subscription", "auto-select":
		return androidRoutePolicyVPN
	default:
		return ""
	}
}

func androidRoutePolicyLabel(policy string) string {
	switch normalizeAndroidRoutePolicy(policy) {
	case androidRoutePolicyAuto:
		return "Авто"
	case androidRoutePolicyDirect:
		return "Напрямую"
	default:
		return "Через VPN"
	}
}

func androidEffectiveRoutePolicy(policy string, hasVPN bool) string {
	policy = normalizeAndroidRoutePolicy(policy)
	if policy == androidRoutePolicyAuto {
		if hasVPN {
			return androidRoutePolicyVPN
		}
		return androidRoutePolicyDirect
	}
	return policy
}

func androidEffectiveRoutePolicies(policies map[string]string, hasVPN bool) map[string]string {
	result := make(map[string]string, len(androidServiceCatalog()))
	for _, service := range androidServiceCatalog() {
		selected := androidServicePolicy(service, policies)
		result[service.Tag] = androidEffectiveRoutePolicy(selected, hasVPN)
	}
	return result
}

func androidEffectiveRoutePoliciesForMode(policies map[string]string, hasVPN bool, routingMode string) map[string]string {
	result := androidEffectiveRoutePolicies(policies, hasVPN)
	if normalizeAndroidRoutingMode(routingMode) != "all_traffic" {
		return result
	}
	// The preset covers every named catalog entry. Unlisted traffic stays direct.
	for tag := range result {
		result[tag] = androidRoutePolicyVPN
	}
	return result
}

func androidRoutePoliciesLocked() map[string]string {
	if len(current.RoutePolicies) == 0 {
		return nil
	}
	result := make(map[string]string, len(current.RoutePolicies))
	for tag, policy := range current.RoutePolicies {
		if normalized := normalizeAndroidRoutePolicy(policy); normalized != "" {
			result[tag] = normalized
		}
	}
	return result
}

func androidServiceRoutesLocked(live bool) []routeInfo {
	_ = live
	policies := androidRoutePoliciesLocked()
	hasVPN := strings.TrimSpace(current.Subscription) != ""
	effectivePolicies := androidEffectiveRoutePoliciesForMode(policies, hasVPN, current.Config.RoutingMode)
	catalog := androidServiceCatalog()
	routes := make([]routeInfo, 0, len(catalog))
	for _, service := range catalog {
		selectedPolicy := androidServicePolicy(service, policies)
		effectivePolicy := effectivePolicies[service.Tag]
		methodLabel := androidRoutePolicyLabel(effectivePolicy)
		if current.Connected && current.adaptiveActive[service.Tag] {
			methodLabel = "TLS напрямую · UDP через VPN"
		}
		routes = append(routes, routeInfo{
			Tag:                  service.Tag,
			Name:                 service.Name,
			Method:               methodLabel,
			EffectiveMethodLabel: methodLabel,
			SelectedMethod:       selectedPolicy,
			VPNOnly:              aicatalog.VPNOnly(service.Tag),
			RequiresVPN:          effectivePolicy == androidRoutePolicyVPN,
			HomeVisible:          androidHomeRouteServiceVisibleLocked(service.Tag),
			// Unknown until an explicit health check runs. Never manufacture
			// latency from a connected flag: zero means "not measured".
			DelayMS:        0,
			DomainSuffixes: append([]string(nil), service.DomainSuffixes...),
			IPCidrs:        append([]string(nil), service.IPCIDRs...),
		})
	}
	return routes
}

func androidHomeRouteServiceVisibleLocked(tag string) bool {
	if aicatalog.VPNOnly(tag) {
		return false
	}
	if androidPrimaryHomeRouteTags[tag] {
		return true
	}
	for _, existing := range current.HomeRouteServices {
		if existing == tag {
			return true
		}
	}
	return false
}

func setAndroidHomeRouteServiceVisibleLocked(args []interface{}) map[string]interface{} {
	tag := stringArg(args, 0, "")
	visible := boolArg(args, 1, true)
	if _, ok := androidServiceByTag(tag); !ok {
		return map[string]interface{}{"success": false, "error": "Unknown Android route service: " + tag}
	}
	if androidPrimaryHomeRouteTags[tag] {
		return map[string]interface{}{"success": true, "tag": tag, "visible": true, "primary": true}
	}
	next := make([]string, 0, len(current.HomeRouteServices)+1)
	seen := map[string]bool{}
	for _, existing := range current.HomeRouteServices {
		if existing == "" || existing == tag || androidPrimaryHomeRouteTags[existing] || seen[existing] {
			continue
		}
		seen[existing] = true
		next = append(next, existing)
	}
	if visible {
		next = append(next, tag)
	}
	current.HomeRouteServices = next
	_ = saveLocked()
	return map[string]interface{}{"success": true, "tag": tag, "visible": visible}
}

func androidRouteMethodOptions() []map[string]string {
	return []map[string]string{
		{"tag": androidRoutePolicyAuto, "label": androidRoutePolicyLabel(androidRoutePolicyAuto)},
		{"tag": androidRoutePolicyDirect, "label": androidRoutePolicyLabel(androidRoutePolicyDirect)},
		{"tag": androidRoutePolicyVPN, "label": androidRoutePolicyLabel(androidRoutePolicyVPN)},
	}
}

func androidRouteMethodCache(services []routeInfo) map[string]string {
	result := make(map[string]string, len(services))
	for _, service := range services {
		result[service.Tag] = service.SelectedMethod
	}
	return result
}

func androidProtectedIdentities() (domains, packages []string) {
	for _, svc := range androidServiceCatalog() {
		if aicatalog.VPNOnly(svc.Tag) {
			domains = append(domains, svc.DomainSuffixes...)
			packages = append(packages, svc.PackageNames...)
		}
	}
	return domains, packages
}

func androidServiceDomainSuffixesByPolicy(policies map[string]string, policy string) []string {
	policy = normalizeAndroidRoutePolicy(policy)
	if policy == "" {
		return nil
	}
	result := []string{}
	for _, service := range androidServiceCatalog() {
		if androidServicePolicy(service, policies) != policy {
			continue
		}
		result = append(result, service.DomainSuffixes...)
	}
	return uniqueNonEmptyStrings(result)
}

func androidServiceIPCIDRsByPolicy(policies map[string]string, policy string) []string {
	policy = normalizeAndroidRoutePolicy(policy)
	if policy == "" {
		return nil
	}
	result := []string{}
	for _, service := range androidServiceCatalog() {
		if androidServicePolicy(service, policies) != policy {
			continue
		}
		result = append(result, service.IPCIDRs...)
	}
	return uniqueNonEmptyStrings(result)
}

func androidServicePackageNamesByPolicy(policies map[string]string, policy string) []string {
	policy = normalizeAndroidRoutePolicy(policy)
	if policy == "" {
		return nil
	}
	result := []string{}
	for _, service := range androidServiceCatalog() {
		if androidServicePolicy(service, policies) != policy {
			continue
		}
		result = append(result, service.PackageNames...)
	}
	return uniqueNonEmptyStrings(result)
}

// Android excludes the Dropo package from its own TUN. Until quick checks use
// a dedicated loopback inbound, an ordinary HTTP request proves endpoint
// reachability only; it must never claim that the request used the VPN route.
func androidClientQuickCheckResult(service routeInfo, target string, statusCode int, errText string, latencyMS int) map[string]interface{} {
	expectedRoute := androidRoutePolicyDirect
	if service.RequiresVPN {
		expectedRoute = androidRoutePolicyVPN
	}
	success := strings.TrimSpace(errText) == ""
	statusText := "FAIL"
	if success {
		statusText = "ENDPOINT_OK"
	}
	return map[string]interface{}{
		"tag":           service.Tag,
		"serviceTag":    service.Tag,
		"name":          service.Name,
		"success":       success,
		"target":        target,
		"url":           target,
		"status":        statusCode,
		"statusText":    statusText,
		"error":         errText,
		"latencyMs":     latencyMS,
		"methodTag":     expectedRoute,
		"expectedRoute": expectedRoute,
		"methodLabel":   service.EffectiveMethodLabel,
		"routeVerified": false,
		"checkScope":    "endpoint_reachability",
	}
}

func runAndroidClientQuickCheck() string {
	return runAndroidClientQuickCheckMode(false)
}

// Help checks observe endpoints only. They must not persist logs, mutate route
// policy or publish events that can be interpreted as a connection operation.
// Owned by the currently running libbox instance. A check queued during a
// disconnect must fail before opening a socket on a later session.
var androidVPNCheck struct {
	generation int64
	session    context.Context
	client     *http.Client
}

func RegisterAndroidVPNCheckClient(generation int64, session context.Context, client *http.Client) {
	mu.Lock()
	defer mu.Unlock()
	if current.sourceSession == generation && generation != 0 {
		androidVPNCheck.generation, androidVPNCheck.session, androidVPNCheck.client = generation, session, client
	}
}

func runAndroidClientQuickCheckMode(readOnly bool) string {
	return runAndroidClientQuickCheckWithProbe(readOnly, probeAndroidService)
}

func runAndroidClientQuickCheckWithProbe(readOnly bool, probe func(context.Context, *http.Client, string) (int, string)) string {
	startedAt := time.Now()
	mu.Lock()
	services := androidServiceRoutesLocked(true)
	vpnCheck := androidVPNCheck
	if vpnCheck.generation != current.sourceSession || current.sourceSession == 0 {
		vpnCheck.client = nil
	}
	sessionStartedAt := current.StartedAt
	sessionNumber := current.TotalSessions
	sessionWasConnected := current.Connected
	startServices := make([]map[string]interface{}, 0, len(services))
	for _, service := range services {
		startServices = append(startServices, map[string]interface{}{"tag": service.Tag, "name": service.Name})
	}
	if !readOnly {
		appendLogLocked(fmt.Sprintf("android service quick check started (%d services)", len(services)))
		emitLocked("client-check-start", map[string]interface{}{
			"total":        len(services),
			"serviceCount": len(services),
			"services":     startServices,
		})
		_ = saveLocked()
	}
	mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	client := &http.Client{Timeout: 8 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	vpnCtx, cancelVPN := context.WithCancel(ctx)
	defer cancelVPN()
	if vpnCheck.session != nil {
		stop := context.AfterFunc(vpnCheck.session, cancelVPN)
		defer stop()
		if vpnCheck.session.Err() != nil {
			cancelVPN()
		}
	}
	results := make([]map[string]interface{}, len(services))
	jobs := make(chan int)
	workers := 8
	if workers > len(services) {
		workers = len(services)
	}
	var workersDone sync.WaitGroup
	for worker := 0; worker < workers; worker++ {
		workersDone.Add(1)
		go func() {
			defer workersDone.Done()
			for index := range jobs {
				service := services[index]
				target := androidServiceHealthTarget(service.Tag)
				probeStarted := time.Now()
				checkCtx, checkClient := ctx, client
				if service.RequiresVPN || service.VPNOnly {
					checkCtx, checkClient = vpnCtx, vpnCheck.client
				}
				statusCode, errText := probe(checkCtx, checkClient, target)
				delayMS := int(time.Since(probeStarted).Milliseconds())
				result := androidClientQuickCheckResult(service, target, statusCode, errText, delayMS)
				results[index] = result

				if !readOnly {
					mu.Lock()
					emitLocked("client-check-service", result)
					if result["success"] == true {
						appendLogLocked(fmt.Sprintf("android service quick check ok: %s %s (%d ms)", service.Tag, target, delayMS))
					} else {
						appendLogLocked(fmt.Sprintf("android service quick check failed: %s %s: %s", service.Tag, target, errText))
					}
					_ = saveLocked()
					mu.Unlock()
				}
			}
		}()
	}

enqueue:
	for index := range services {
		select {
		case <-ctx.Done():
			break enqueue
		case jobs <- index:
		}
	}
	close(jobs)
	workersDone.Wait()

	failedCount := 0
	okCount := 0
	for index, service := range services {
		if results[index] == nil {
			target := androidServiceHealthTarget(service.Tag)
			results[index] = androidClientQuickCheckResult(
				service,
				target,
				0,
				"quick check deadline exceeded",
				0,
			)
		}
		if results[index]["success"] == true {
			okCount++
		} else {
			failedCount++
		}
	}

	success := failedCount == 0
	payload := map[string]interface{}{
		"success":       success,
		"android":       true,
		"services":      results,
		"total":         len(results),
		"totalCount":    len(results),
		"okCount":       okCount,
		"failedCount":   failedCount,
		"durationMs":    time.Since(startedAt).Milliseconds(),
		"checkedAt":     currentTimeRFC3339(),
		"routeVerified": false,
		"checkScope":    "endpoint_reachability",
		"readOnly":      readOnly,
	}
	if ctx.Err() != nil {
		payload["error"] = ctx.Err().Error()
	}
	mu.Lock()
	payload["sessionValid"] = androidQuickCheckSessionValidLocked(
		sessionStartedAt,
		sessionNumber,
		sessionWasConnected,
	)
	if !readOnly {
		emitLocked("client-check-done", payload)
		appendLogLocked(fmt.Sprintf("android service quick check complete: %d/%d failed", failedCount, len(results)))
		_ = saveLocked()
	}
	mu.Unlock()
	return encode(payload)
}

func androidQuickCheckSessionValidLocked(startedAt string, sessionNumber int, wasConnected bool) bool {
	return wasConnected &&
		current.Connected &&
		current.TotalSessions == sessionNumber &&
		current.StartedAt == startedAt
}

func androidServiceHealthTarget(tag string) string {
	service, ok := androidServiceByTag(tag)
	if !ok {
		return "https://www.gstatic.com/generate_204"
	}
	if strings.TrimSpace(service.HealthURL) != "" {
		return strings.TrimSpace(service.HealthURL)
	}
	for _, target := range service.ProbeURLs {
		if strings.TrimSpace(target) != "" {
			return strings.TrimSpace(target)
		}
	}
	if len(service.DomainSuffixes) > 0 {
		return "https://" + strings.TrimPrefix(service.DomainSuffixes[0], ".")
	}
	return "https://www.gstatic.com/generate_204"
}

func probeAndroidService(ctx context.Context, client *http.Client, target string) (int, string) {
	if client == nil {
		return 0, "VPN недоступен"
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return 0, err.Error()
	}
	request.Header.Set("User-Agent", "dropo-android-check/1.0")
	response, err := client.Do(request)
	if err != nil {
		return 0, err.Error()
	}
	defer response.Body.Close()
	_, _ = io.CopyN(io.Discard, response.Body, 4096)
	if response.StatusCode >= 200 && response.StatusCode < 500 {
		return response.StatusCode, ""
	}
	return response.StatusCode, response.Status
}

func uniqueNonEmptyStrings(values []string) []string {
	seen := make(map[string]bool, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		result = append(result, value)
	}
	return result
}
