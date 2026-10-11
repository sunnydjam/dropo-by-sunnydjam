package dropoandroid

import (
	"bufio"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

// Only the synthetic remote VLESS/XHTTP server runs in this test helper.
// The pinned upstream server's uploadQueue/ResponseWriter shutdown races are
// not Android client code. Every production client, protected dialer, bridge,
// selector, and managed session remains in the parent with its race detector.
// testdata and *_test.go files are never included in the Android binding/APK.
var xhttpFixtureExecutable struct {
	sync.Once
	path string
	dir  string
	err  error
}

func TestMain(m *testing.M) {
	code := m.Run()
	if xhttpFixtureExecutable.dir != "" {
		// The directory is allocated only by MkdirTemp under the system temp
		// root. Verify that exact resolved target before recursive cleanup.
		target, err := filepath.Abs(xhttpFixtureExecutable.dir)
		temporaryRoot, rootErr := filepath.Abs(os.TempDir())
		if err != nil || rootErr != nil || filepath.Dir(target) != temporaryRoot ||
			!strings.HasPrefix(filepath.Base(target), "dropo-xhttp-server-fixture-") {
			code = 1
		} else if os.RemoveAll(target) != nil {
			code = 1
		}
	}
	os.Exit(code)
}

func xhttpFixtureBinary(t *testing.T) string {
	t.Helper()
	xhttpFixtureExecutable.Do(func() {
		xhttpFixtureExecutable.dir, xhttpFixtureExecutable.err = os.MkdirTemp("", "dropo-xhttp-server-fixture-")
		if xhttpFixtureExecutable.err != nil {
			return
		}
		name, goName := "xhttp-server", "go"
		if runtime.GOOS == "windows" {
			name += ".exe"
			goName += ".exe"
		}
		xhttpFixtureExecutable.path = filepath.Join(xhttpFixtureExecutable.dir, name)
		goCommand := filepath.Join(runtime.GOROOT(), "bin", goName)
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		// Preserve the exact pinned modfile/overlay and build tags inherited
		// from CI. Only this remote fixture binary is not race-instrumented;
		// the parent `go test -race ./...` remains entirely unchanged.
		command := exec.CommandContext(ctx, goCommand, "build", "-race=false", "-ldflags=-checklinkname=0", "-o", xhttpFixtureExecutable.path, "./testdata/xhttp_server")
		if err := command.Run(); err != nil {
			xhttpFixtureExecutable.err = errors.New("synthetic remote XHTTP server fixture could not compile")
		}
	})
	if xhttpFixtureExecutable.err != nil {
		t.Fatal(xhttpFixtureExecutable.err)
	}
	return xhttpFixtureExecutable.path
}

func startXHTTPFixtureProcess(t *testing.T, config []byte) {
	t.Helper()
	if len(config) == 0 || len(config) > 64*1024 || strings.ContainsAny(string(config), "\r\n") {
		t.Fatal("synthetic server fixture config is not bounded single-line JSON")
	}
	command := exec.Command(xhttpFixtureBinary(t))
	input, err := command.StdinPipe()
	if err != nil {
		t.Fatal("synthetic server fixture input could not open")
	}
	output, err := command.StdoutPipe()
	if err != nil {
		input.Close()
		t.Fatal("synthetic server fixture readiness output could not open")
	}
	if err := command.Start(); err != nil {
		input.Close()
		output.Close()
		t.Fatal("synthetic server fixture could not start")
	}
	waited := make(chan error, 1)
	go func() { waited <- command.Wait() }()
	var stop sync.Once
	cleanup := func() {
		stop.Do(func() {
			input.Close() // EOF requests graceful server shutdown.
			select {
			case <-waited:
			case <-time.After(2 * time.Second):
				command.Process.Kill()
				select {
				case <-waited:
				case <-time.After(2 * time.Second):
					t.Error("synthetic server fixture process failed to stop")
				}
			}
			output.Close()
		})
	}
	t.Cleanup(cleanup)
	delivered := make(chan error, 1)
	go func() {
		_, err := input.Write(append(config, '\n'))
		delivered <- err
	}()
	select {
	case err := <-delivered:
		if err != nil {
			cleanup()
			t.Fatal("synthetic server fixture config delivery failed")
		}
	case <-time.After(10 * time.Second):
		cleanup()
		t.Fatal("synthetic server fixture config delivery timed out")
	}
	ready := make(chan bool, 1)
	go func() {
		reader := bufio.NewReaderSize(output, 128)
		line, err := reader.ReadSlice('\n')
		ready <- err == nil && string(line) == "READY\n"
	}()
	select {
	case ok := <-ready:
		if !ok {
			cleanup()
			t.Fatal("synthetic server fixture did not become ready")
		}
	case <-time.After(10 * time.Second):
		cleanup()
		t.Fatal("synthetic server fixture readiness timed out")
	}
}
