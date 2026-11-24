// Package residential resolves private, per-subscription relay assignments.
package residential

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"dropocore/catalog"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const suffix = ".residential.dropo.invalid"

var unavailable = errors.New("residential entry unavailable")

type Dial func(context.Context, string, string) (net.Conn, error)

// The internal name carries only a one-way directory locator. Never resolve it over DNS.
func Host(primary, pool string) string {
	value, err := hex.DecodeString(strings.ReplaceAll(primary, "-", ""))
	if err != nil || len(value) != 16 {
		return ""
	}
	h := sha256.Sum256(append([]byte("dropo-residential-lookup-v1:"), value...))
	tag := hex.EncodeToString(h[:])
	return tag[:32] + "." + tag[32:] + "." + pool + suffix
}

type assignment struct {
	Purpose, Pool, Locator, IP string
	Port                       uint16
	Issued, Expires            int64
	envelope                   []byte
}
type Client struct {
	pool, locator string
	key           [32]byte
	mu            sync.Mutex
	current       assignment
	cachePath     string
	roots         *x509.CertPool
}

func (c *Client) UsePlatformRoots(pems []string) error {
	roots := x509.NewCertPool()
	count := 0
	for _, pem := range pems {
		if roots.AppendCertsFromPEM([]byte(pem)) {
			count++
		}
	}
	if count == 0 {
		return unavailable
	}
	c.roots = roots
	return nil
}

// Cache only authenticated ciphertext in the platform's application data directory.
func (c *Client) CacheAt(dir string) {
	if dir == "" {
		return
	}
	dir = filepath.Join(dir, "residential")
	if os.MkdirAll(dir, 0700) != nil {
		return
	}
	c.cachePath = filepath.Join(dir, c.locator+".bin")
	f, err := os.Open(c.cachePath)
	if err != nil {
		return
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, 2049))
	if err == nil && len(raw) <= 2048 {
		if a, err := c.open(raw, time.Now().Unix()); err == nil {
			c.current = a
		}
	}
}

func (c *Client) save(data []byte) {
	if c.cachePath == "" {
		return
	}
	tmp, err := os.CreateTemp(filepath.Dir(c.cachePath), ".entry-")
	if err != nil {
		return
	}
	defer os.Remove(tmp.Name())
	_, err = tmp.Write(data)
	closed := tmp.Close()
	if err == nil && closed == nil {
		_ = os.Rename(tmp.Name(), c.cachePath)
	}
}

func ForHost(host, credential string) *Client {
	name, ok := strings.CutSuffix(host, suffix)
	if !ok {
		return nil
	}
	parts := strings.Split(name, ".")
	if len(parts) != 3 || len(parts[0]) != 32 || len(parts[1]) != 32 || parts[2] != "free" && parts[2] != "boost" {
		return nil
	}
	id := parts[0] + parts[1]
	if _, err := hex.DecodeString(id); err != nil {
		return nil
	}
	return &Client{locator: id, pool: parts[2], key: sha256.Sum256([]byte("dropo-residential-wrap-v1:" + credential))}
}

func Reserved(host string) bool { return strings.HasSuffix(host, suffix) }

// Both native runtimes read the same strictly scoped Xray VLESS/XHTTP outbound.
func FromOutbound(out map[string]any) (*Client, map[string]any, error) {
	settings, _ := out["settings"].(map[string]any)
	nodes, _ := settings["vnext"].([]any)
	if len(nodes) != 1 {
		return nil, nil, nil
	}
	node, _ := nodes[0].(map[string]any)
	host, _ := node["address"].(string)
	if !Reserved(host) {
		return nil, nil, nil
	}
	users, _ := node["users"].([]any)
	if len(users) != 1 {
		return nil, nil, unavailable
	}
	user, _ := users[0].(map[string]any)
	id, _ := user["id"].(string)
	c := ForHost(host, id)
	if c == nil || len(id) != 36 {
		return nil, nil, unavailable
	}
	name := "lv1.dropo.fun"
	if c.pool == "boost" {
		name = "fi1.dropo.fun"
	}
	stream, _ := out["streamSettings"].(map[string]any)
	tlsCfg, _ := stream["tlsSettings"].(map[string]any)
	httpCfg, _ := stream["xhttpSettings"].(map[string]any)
	if out["protocol"] != "vless" || stream["network"] != "xhttp" || stream["security"] != "tls" || tlsCfg["serverName"] != name || (tlsCfg["allowInsecure"] != nil && tlsCfg["allowInsecure"] != false) || httpCfg["host"] != name || httpCfg["path"] != "/managed/v1/"+c.pool {
		return nil, nil, unavailable
	}
	return c, node, nil
}

func (c *Client) open(data []byte, now int64) (assignment, error) {
	return c.decode(data, now, catalog.VerifyDeploymentSignature)
}

func (c *Client) decode(data []byte, now int64, verify func([]byte, []byte) bool) (assignment, error) {
	var a assignment
	block, _ := aes.NewCipher(c.key[:])
	seal, err := cipher.NewGCMWithRandomNonce(block)
	if err != nil {
		return a, unavailable
	}
	plain, err := seal.Open(nil, nil, data, []byte(c.locator))
	if err != nil || len(plain) <= ed25519.SignatureSize || !verify(plain[64:], plain[:64]) || json.Unmarshal(plain[64:], &a) != nil {
		return assignment{}, unavailable
	}
	expected := uint16(34443)
	if c.pool == "boost" {
		expected = 34444
	}
	ip, err := netip.ParseAddr(a.IP)
	if a.Purpose != "dropo-residential-xhttp-v1" || a.Pool != c.pool || a.Locator != c.locator || a.Port != expected || a.Issued > now+30 || a.Expires <= now || a.Expires <= a.Issued || a.Expires-a.Issued > 480 || err != nil || !ip.Is4() || !ip.IsGlobalUnicast() || ip.IsPrivate() || netip.MustParsePrefix("100.64.0.0/10").Contains(ip) {
		return assignment{}, unavailable
	}
	return a, nil
}

type origin struct{ name, ip, prefix string }

var origins = []origin{{"app.droponevedimka.ru", "109.120.152.117", ""}, {"ms-api.ordaflow.net", "91.229.239.99", "/dropo-subscription"}, {"dropo.fun", "77.42.65.119", ""}}

func (c *Client) fetch(ctx context.Context, dial Dial, o origin) (assignment, error) {
	transport := &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: c.roots}, DisableKeepAlives: true, DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return dial(ctx, "tcp4", net.JoinHostPort(o.ip, "443"))
	}}
	defer transport.CloseIdleConnections()
	url := "https://" + o.name + o.prefix + "/managed/v1/subscription/r2." + c.locator
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return assignment{}, unavailable
	}
	resp, err := transport.RoundTrip(req)
	if err != nil {
		return assignment{}, unavailable
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return assignment{}, unavailable
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 2049))
	if err != nil || len(raw) > 2048 {
		return assignment{}, unavailable
	}
	a, err := c.open(raw, time.Now().Unix())
	if err == nil {
		a.envelope = raw
	}
	return a, err
}

func (c *Client) resolve(ctx context.Context, dial Dial, force bool) (assignment, error) {
	c.mu.Lock()
	old := c.current
	c.mu.Unlock()
	if !force && old.Expires > time.Now().Unix() && time.Now().Unix()-old.Issued < 120 {
		return old, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 6*time.Second)
	defer cancel()
	results := make(chan assignment, len(origins))
	for _, o := range origins {
		go func() { v, _ := c.fetch(ctx, dial, o); results <- v }()
	}
	for range origins {
		select {
		case <-ctx.Done():
			if !force && old.Expires > time.Now().Unix() && ctx.Err() == context.DeadlineExceeded {
				return old, nil
			}
			return assignment{}, unavailable
		case v := <-results:
			if v.Issued == 0 {
				continue
			}
			c.mu.Lock()
			if v.Issued >= c.current.Issued && (v.Issued != c.current.Issued || v.IP == c.current.IP) {
				if v.Issued > c.current.Issued {
					c.save(v.envelope)
				}
				c.current = v
			}
			best := c.current
			c.mu.Unlock()
			if best.Expires > time.Now().Unix() {
				return best, nil
			}
		}
	}
	if !force && old.Expires > time.Now().Unix() {
		return old, nil
	}
	return assignment{}, unavailable
}

func (c *Client) Connect(ctx context.Context, dial Dial) (net.Conn, error) {
	return connectWithRefresh(ctx, dial, c.resolve)
}

func connectWithRefresh(ctx context.Context, dial Dial, resolve func(context.Context, Dial, bool) (assignment, error)) (net.Conn, error) {
	a, err := resolve(ctx, dial, false)
	if err != nil {
		return nil, err
	}
	open := func(v assignment) (net.Conn, error) {
		bounded, cancel := context.WithTimeout(ctx, 4*time.Second)
		defer cancel()
		return dial(bounded, "tcp4", netip.AddrPortFrom(netip.MustParseAddr(v.IP), v.Port).String())
	}
	conn, err := open(a)
	if err == nil {
		return conn, nil
	}
	next, err := resolve(ctx, dial, true)
	if err != nil || next.IP == a.IP {
		return nil, unavailable
	}
	return open(next)
}
