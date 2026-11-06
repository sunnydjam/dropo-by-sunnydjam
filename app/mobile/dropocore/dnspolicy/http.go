package dnspolicy

import (
	"context"
	"net"
	"net/http"
	"strings"
	"time"
)

// Bootstrap only the compiled deployment names. SNI/Host remain the original
// request hostname and net/http performs normal certificate verification.
func InfrastructureTransport() *http.Transport {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(address)
		if err != nil {
			return nil, err
		}
		switch strings.ToLower(host) {
		case "api.droponevedimka.ru", "app.droponevedimka.ru", "cdn.droponevedimka.ru", "dns.droponevedimka.ru":
			address = net.JoinHostPort(BootstrapIPv4, port)
		}
		return (&net.Dialer{Timeout: 6 * time.Second, KeepAlive: 30 * time.Second}).DialContext(ctx, network, address)
	}
	return transport
}
