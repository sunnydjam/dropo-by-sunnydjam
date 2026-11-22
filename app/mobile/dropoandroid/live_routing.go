package dropoandroid

import (
	core "dropocore"
	"encoding/json"
	"errors"
)

// ApplyRoutingChange runs on the Android service worker. It reuses the
// prepared outbound pool and does not fetch or reorder subscriptions.
func (s *CommandServer) ApplyRoutingChange(method, args string) (string, error) {
	previous := s.routingConfig
	var activeID, activeTag string
	var attempted bool
	result, err := core.ApplyAndroidRoutingChange(method, args, previous, func(config string) error {
		if !attempted {
			if config == previous {
				return nil // Validation failed before the old engine was touched.
			}
			if err := CheckConfig(config); err != nil {
				return err
			}
			s.sourceMu.Lock()
			activeID, activeTag = core.ActiveAndroidSource()
			s.stopSourceSelectionLocked()
			s.sourceMu.Unlock()
			attempted = true
		}
		config, err := keepRoutingSource(config, activeTag)
		if err != nil {
			return err
		}
		return s.StartOrReloadService(config, nil)
	})
	if err != nil || !attempted {
		return result, err
	}
	// User Stop cancels the Go plan immediately. Kotlin's session fence
	// prevents a cancelled operation from establishing a new TUN.
	_ = s.startSourceSelection(activeID)
	return result, nil
}

func keepRoutingSource(config, tag string) (string, error) {
	if tag == "" {
		return config, nil
	}
	var parsed map[string]json.RawMessage
	var outbounds []map[string]json.RawMessage
	if json.Unmarshal([]byte(config), &parsed) != nil || json.Unmarshal(parsed["outbounds"], &outbounds) != nil {
		return "", errors.New("invalid Android route reload configuration")
	}
	for _, outbound := range outbounds {
		if string(outbound["tag"]) != `"proxy"` {
			continue
		}
		var choices []string
		if err := json.Unmarshal(outbound["outbounds"], &choices); err != nil {
			return "", err
		}
		for _, choice := range choices {
			if choice == tag {
				outbound["default"], _ = json.Marshal(tag)
				parsed["outbounds"], _ = json.Marshal(outbounds)
				data, err := json.Marshal(parsed)
				return string(data), err
			}
		}
	}
	return "", errors.New("active Android VPN source is missing from the route reload")
}
