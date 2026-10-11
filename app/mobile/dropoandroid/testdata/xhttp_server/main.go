// This executable is a synthetic remote VPN server used only by Go tests.
// It is not imported, bound by gomobile, shipped in an APK, or invoked at runtime.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"

	_ "github.com/xtls/xray-core/app/dispatcher"
	_ "github.com/xtls/xray-core/app/dns"
	_ "github.com/xtls/xray-core/app/log"
	_ "github.com/xtls/xray-core/app/proxyman/inbound"
	_ "github.com/xtls/xray-core/app/proxyman/outbound"
	xcore "github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf"
	_ "github.com/xtls/xray-core/proxy/freedom"
	_ "github.com/xtls/xray-core/proxy/vless/inbound"
	_ "github.com/xtls/xray-core/transport/internet/splithttp"
	_ "github.com/xtls/xray-core/transport/internet/tcp"
	_ "github.com/xtls/xray-core/transport/internet/tls"
)

func run() error {
	input := bufio.NewReaderSize(os.Stdin, 64*1024+2)
	raw, err := input.ReadSlice('\n')
	if err != nil || len(raw) > 64*1024+1 {
		return io.ErrUnexpectedEOF
	}
	var config conf.Config
	decoder := json.NewDecoder(bytes.NewReader(raw))
	if err := decoder.Decode(&config); err != nil {
		return err
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return io.ErrUnexpectedEOF
	}
	built, err := config.Build()
	if err != nil {
		return err
	}
	server, err := xcore.NewWithContext(context.Background(), built)
	if err != nil {
		return err
	}
	defer server.Close()
	if err := server.Start(); err != nil {
		return err
	}
	if _, err := io.WriteString(os.Stdout, "READY\n"); err != nil {
		return err
	}
	// The test owns stdin; closing it is the graceful lifetime boundary.
	_, err = io.Copy(io.Discard, input)
	return err
}

func main() {
	if run() != nil {
		// Configuration and TLS material are synthetic but never echo config
		// or raw upstream errors into CI output; readiness failure is enough.
		os.Exit(1)
	}
}
