package dropocore

import (
	"context"
	"encoding/json"
	"net/http"
	"reflect"
	"testing"
)

func TestAndroidHelpCheckDoesNotChangeStateLogsOrEvents(t *testing.T) {
	mu.Lock()
	previous := current
	current = defaultState()
	current.Connected = true
	current.StartedAt = "fixture-session"
	current.TotalSessions = 1
	before, _ := json.Marshal(current)
	mu.Unlock()
	t.Cleanup(func() {
		mu.Lock()
		current = previous
		mu.Unlock()
	})
	var report map[string]interface{}
	raw := runAndroidClientQuickCheckWithProbe(true, func(context.Context, *http.Client, string) (int, string) {
		return http.StatusNoContent, ""
	})
	if err := json.Unmarshal([]byte(raw), &report); err != nil {
		t.Fatal(err)
	}
	if report["readOnly"] != true || report["sessionValid"] != true || report["success"] != true || report["routeVerified"] != false {
		t.Fatalf("unexpected endpoint-only summary: %#v", report)
	}
	mu.Lock()
	after, _ := json.Marshal(current)
	mu.Unlock()
	if !reflect.DeepEqual(before, after) {
		t.Fatal("help check changed persistent state, logs or events")
	}
}

func TestAndroidReadOnlyCheckDoesNotAcceptReconnect(t *testing.T) {
	mu.Lock()
	previous := current
	current = defaultState()
	current.Connected = true
	current.TotalSessions = 1
	mu.Unlock()
	t.Cleanup(func() {
		mu.Lock()
		current = previous
		mu.Unlock()
	})
	raw := runAndroidClientQuickCheckWithProbe(true, func(context.Context, *http.Client, string) (int, string) {
		mu.Lock()
		current.TotalSessions++
		mu.Unlock()
		return http.StatusNoContent, ""
	})
	var report map[string]interface{}
	if err := json.Unmarshal([]byte(raw), &report); err != nil {
		t.Fatal(err)
	}
	if report["sessionValid"] != false {
		t.Fatal("read-only result survived a session change")
	}
}
