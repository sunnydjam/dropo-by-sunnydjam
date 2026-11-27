//go:build windows

package main

import "testing"

func TestOnlyDropoPACIdentifiesOwnedProxy(t *testing.T) {
	tests := []struct {
		value string
		want  int
	}{
		{"127.0.0.1:2088", 0},
		{"http=127.0.0.1:2088;https=localhost:2088", 0},
		{"http://127.0.0.1:7301/proxy.pac", 0},
		{"proxy.example:8080", 0},
		{"http://127.0.0.1:32101/dropo-selective-0123456789abcdef0123456789abcdef.pac?revision=1", 32101},
		{"http://proxy.example:32101/dropo-selective-0123456789abcdef0123456789abcdef.pac", 0},
		{"", 0},
	}
	for _, test := range tests {
		if got := dropoPACPort(test.value); got != test.want {
			t.Errorf("dropoPACPort(%q) = %d, want %d", test.value, got, test.want)
		}
	}
}
