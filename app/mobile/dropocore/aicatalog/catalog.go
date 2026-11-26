// Package aicatalog contains the AI routing identities shared by both native clients.
package aicatalog

type Service struct {
	Tag, Name, HealthURL                    string
	Domains, Processes, Packages, ProbeURLs []string
}

var Services = []Service{
	{
		Tag: "openai", Name: "ChatGPT", HealthURL: "https://chatgpt.com",
		Domains: []string{"openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com", "oaistatsig.com", "openaimerge.com",
			"oaisidekickupdates.blob.core.windows.net", "o207216.ingest.sentry.io", "o33249.ingest.sentry.io"},
		Processes: []string{"ChatGPT.exe", "Codex.exe"}, Packages: []string{"com.openai.chatgpt"},
		ProbeURLs: []string{"https://api.openai.com"},
	},
	{
		Tag: "claude", Name: "Claude", HealthURL: "https://claude.ai",
		Domains:   []string{"claude.ai", "claude.com", "anthropic.com", "claude.app", "claudeusercontent.com", "claudemcpcontent.com"},
		Processes: []string{"Claude.exe"}, Packages: []string{"com.anthropic.claude"},
		ProbeURLs: []string{"https://api.anthropic.com"},
	},
	{
		Tag: "ai-other", Name: "Другие ИИ-сервисы", HealthURL: "https://perplexity.ai",
		// Shared sign-in sites, IDE processes and cloud/CDN suffixes cannot
		// identify a browser or editor request as belonging to an AI service.
		Domains: []string{"githubcopilot.com", "copilot-proxy.githubusercontent.com", "copilot-telemetry.githubusercontent.com",
			"cursor.com", "cursor.sh", "cursorapi.com", "cursor-cdn.com", "copilot.microsoft.com",
			"perplexity.ai", "poe.com", "gemini.google.com", "aistudio.google.com", "ai.google.dev",
			"generativelanguage.googleapis.com", "notebooklm.google.com", "grok.com", "x.ai",
			"meta.ai", "ai.meta.com", "llama.com", "deepseek.com", "mistral.ai"},
		Processes: []string{"Cursor.exe", "GitHubCopilot.exe"},
		Packages:  []string{"com.google.android.apps.bard", "ai.perplexity.app.android", "com.poe.android", "ai.x.grok", "com.deepseek.chat", "ai.mistral.chat"},
		ProbeURLs: []string{"https://gemini.google.com"},
	},
}

// VPNOnly includes the provider-restricted SaaS entries classified as VPNOnly in the service catalog.
func VPNOnly(tag string) bool {
	switch tag {
	case "canva", "notion", "slack", "miro", "wix", "coda", "grammarly", "docker", "clickup", "manychat", "helpscout", "atlassian":
		return true
	}
	for _, s := range Services {
		if tag == s.Tag {
			return true
		}
	}
	return false
}
