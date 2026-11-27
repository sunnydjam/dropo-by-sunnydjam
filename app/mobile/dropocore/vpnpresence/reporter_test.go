package vpnpresence

import (
	"net/http"
	"testing"
	"time"
)

func TestCredentialClearedWhilePresenceRequestIsInFlight(t *testing.T) {
	reporter := &Reporter{
		credential: credential{"https://dropo.fun", "fixture-session"},
		wake:       make(chan struct{}, 1),
	}
	methods := make(chan string, 2)
	unblock := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		reporter.run(reporter.wake, func() bool { return true }, func(method string, _ credential) {
			methods <- method
			if method == http.MethodPost {
				<-unblock
			}
		})
	}()
	awaitMethod := func(want string) {
		t.Helper()
		select {
		case method := <-methods:
			if method != want {
				t.Fatalf("presence method = %s, want %s", method, want)
			}
		case <-time.After(time.Second):
			t.Fatalf("missing %s presence request", want)
		}
	}
	awaitMethod(http.MethodPost)
	reporter.SetCredential("", "", func() bool { return false })
	close(unblock)
	awaitMethod(http.MethodDelete)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("presence worker kept running after credential cleared")
	}
}
