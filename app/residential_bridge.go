package main

import (
	"context"
	"dropocore/residential"
	"encoding/json"
	"io"
	"net"
	"time"
)

// Xray runs in its own process on Windows. A session-owned loopback socket
// keeps dynamic discovery in the signed client and Xray TLS end-to-end.
func prepareResidentialBridges(ctx context.Context, config []byte, cacheDir string) ([]byte, error) {
	var object map[string]any
	if err := json.Unmarshal(config, &object); err != nil {
		return nil, err
	}
	outbounds, _ := object["outbounds"].([]any)
	changed := false
	for _, v := range outbounds {
		out, _ := v.(map[string]any)
		client, node, err := residential.FromOutbound(out)
		if err != nil {
			return nil, err
		}
		if client == nil {
			continue
		}
		client.CacheAt(cacheDir)
		l, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
		if err != nil {
			return nil, err
		}
		context.AfterFunc(ctx, func() { l.Close() })
		node["address"] = "127.0.0.1"
		node["port"] = l.Addr().(*net.TCPAddr).Port
		changed = true
		go runResidentialBridge(ctx, l, client)
	}
	if !changed {
		return config, nil
	}
	return json.Marshal(object)
}

func runResidentialBridge(ctx context.Context, l *net.TCPListener, c *residential.Client) {
	slots := make(chan struct{}, 32)
	for {
		local, err := l.AcceptTCP()
		if err != nil {
			return
		}
		select {
		case slots <- struct{}{}:
		default:
			local.Close()
			continue
		}
		go func() {
			defer func() { <-slots }()
			defer local.Close()
			stopLocal := context.AfterFunc(ctx, func() { local.Close() })
			defer stopLocal()
			dialCtx, cancel := context.WithTimeout(ctx, 12*time.Second)
			upstream, err := c.Connect(dialCtx, dialResidentialPhysical)
			cancel()
			if err != nil {
				return
			}
			defer upstream.Close()
			stopUpstream := context.AfterFunc(ctx, func() { upstream.Close() })
			defer stopUpstream()
			done := make(chan struct{})
			go func() {
				io.Copy(upstream, local)
				if tcp, ok := upstream.(*net.TCPConn); ok {
					tcp.CloseWrite()
				}
				close(done)
			}()
			io.Copy(local, upstream)
			local.Close()
			upstream.Close()
			<-done
		}()
	}
}
