//go:build windows

package wfpguardservice

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"runtime"
	"time"
	"unsafe"

	"dropo/wfpguard"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
)

const (
	PipeName        = `\\.\pipe\DropoWFPGuard-v1`
	requestTimeout  = 5 * time.Second
	responseTimeout = 5 * time.Second
	pipeBufferSize  = wfpguard.MaxRequestBytes + 1
)

var impersonateNamedPipeClient = windows.NewLazySystemDLL("advapi32.dll").NewProc("ImpersonateNamedPipeClient")

// CanonicalUserSID is required before a SID is interpolated into a pipe DACL.
func CanonicalUserSID(value string) (string, error) {
	if len(value) < 8 || len(value) > 184 {
		return "", errors.New("invalid configured user SID")
	}
	sid, err := windows.StringToSid(value)
	if err != nil || sid == nil || !sid.IsValid() || sid.String() != value {
		return "", errors.New("configured user SID must be canonical")
	}
	return value, nil
}

// PipeServer owns its first pipe instance for its entire lifetime. This
// prevents another process from claiming the well-known name between clients.
type PipeServer struct {
	pipe    windows.Handle
	handler *Handler
}

func NewPipeServer(configuredUserSID string) (*PipeServer, error) {
	return newPipeServer(PipeName, configuredUserSID)
}

func newPipeServer(pipeName, configuredUserSID string) (*PipeServer, error) {
	sid, err := CanonicalUserSID(configuredUserSID)
	if err != nil {
		return nil, err
	}
	handler, err := NewHandler(sid)
	if err != nil {
		return nil, err
	}
	// Client ACE grants file read/write data and metadata rights but not
	// FILE_APPEND_DATA (the same bit as FILE_CREATE_PIPE_INSTANCE). A narrower
	// data-only ACE fails Windows CreateFile's pipe access check. SYSTEM and
	// Administrators may own the pipe, but each request still checks its
	// impersonated client SID.
	sddl := "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x12019B;;;" + sid + ")"
	sd, err := windows.SecurityDescriptorFromString(sddl)
	if err != nil {
		return nil, fmt.Errorf("create guard pipe DACL: %w", err)
	}
	name, err := windows.UTF16PtrFromString(pipeName)
	if err != nil {
		return nil, err
	}
	sa := windows.SecurityAttributes{
		Length:             uint32(unsafe.Sizeof(windows.SecurityAttributes{})),
		SecurityDescriptor: sd,
	}
	pipe, err := windows.CreateNamedPipe(
		name,
		windows.PIPE_ACCESS_DUPLEX|windows.FILE_FLAG_OVERLAPPED|windows.FILE_FLAG_FIRST_PIPE_INSTANCE,
		windows.PIPE_TYPE_MESSAGE|windows.PIPE_READMODE_MESSAGE|windows.PIPE_WAIT|windows.PIPE_REJECT_REMOTE_CLIENTS,
		1, pipeBufferSize, pipeBufferSize, 0, &sa,
	)
	runtime.KeepAlive(sd)
	if err != nil {
		return nil, fmt.Errorf("create guard pipe: %w", err)
	}
	return &PipeServer{pipe: pipe, handler: handler}, nil
}

func (s *PipeServer) Close() error {
	if s == nil || s.pipe == 0 {
		return nil
	}
	err := windows.CloseHandle(s.pipe)
	s.pipe = 0
	return err
}

func (s *PipeServer) Run(ctx context.Context) error {
	if s == nil || s.pipe == 0 {
		return errors.New("guard pipe is not initialized")
	}
	for ctx.Err() == nil {
		if err := s.accept(ctx); err != nil {
			if ctx.Err() != nil {
				return nil
			}
			// A client can disconnect before ConnectNamedPipe completes. Reset
			// that instance and keep serving; malformed clients must not stop
			// the service or cause a tight retry loop.
			if errors.Is(err, windows.ERROR_NO_DATA) ||
				errors.Is(err, windows.ERROR_BROKEN_PIPE) ||
				errors.Is(err, windows.ERROR_PIPE_LISTENING) {
				_ = windows.DisconnectNamedPipe(s.pipe)
				select {
				case <-ctx.Done():
					return nil
				case <-time.After(50 * time.Millisecond):
				}
				continue
			}
			return fmt.Errorf("accept guard client: %w", err)
		}
		s.serveOne(ctx)
		_ = windows.DisconnectNamedPipe(s.pipe)
	}
	return nil
}

func (s *PipeServer) accept(ctx context.Context) error {
	ov, closeEvent, err := newOverlappedEvent()
	if err != nil {
		return err
	}
	defer closeEvent()
	err = windows.ConnectNamedPipe(s.pipe, &ov)
	switch err {
	case nil, windows.ERROR_PIPE_CONNECTED:
		return nil
	case windows.ERROR_IO_PENDING:
		return waitOverlapped(ctx, s.pipe, &ov, 0)
	default:
		return err
	}
}

func (s *PipeServer) serveOne(ctx context.Context) {
	message, err := readMessage(ctx, s.pipe)
	if err != nil {
		return
	}
	callerSID, err := callerSIDFromPipe(s.pipe)
	if err != nil || callerSID != s.handler.allowedUserSID {
		return
	}
	request, err := wfpguard.DecodeRequest(bytes.NewReader(message))
	if err != nil {
		return
	}
	response := s.handler.Handle(callerSID, request)
	encoded, err := json.Marshal(response)
	if err != nil {
		return
	}
	_ = writeMessage(ctx, s.pipe, encoded)
}

// ImpersonateNamedPipeClient uses the *last message read* from this pipe.
// Locking the OS thread prevents a goroutine switch while querying and
// reverting its impersonation token.
func callerSIDFromPipe(pipe windows.Handle) (string, error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	r1, _, callErr := impersonateNamedPipeClient.Call(uintptr(pipe))
	if r1 == 0 {
		return "", fmt.Errorf("impersonate guard client: %w", callErr)
	}
	defer func() {
		// Continuing a privileged service on an impersonated thread is unsafe.
		if err := windows.RevertToSelf(); err != nil {
			os.Exit(1)
		}
	}()
	var token windows.Token
	if err := windows.OpenThreadToken(windows.CurrentThread(), windows.TOKEN_QUERY, true, &token); err != nil {
		return "", err
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil || user == nil || user.User.Sid == nil {
		return "", errors.New("guard client token has no user SID")
	}
	return user.User.Sid.String(), nil
}

func newOverlappedEvent() (windows.Overlapped, func(), error) {
	event, err := windows.CreateEvent(nil, 1, 0, nil)
	if err != nil {
		return windows.Overlapped{}, nil, err
	}
	return windows.Overlapped{HEvent: event}, func() { _ = windows.CloseHandle(event) }, nil
}

func waitOverlapped(ctx context.Context, handle windows.Handle, ov *windows.Overlapped, timeout time.Duration) error {
	deadline := time.Time{}
	if timeout > 0 {
		deadline = time.Now().Add(timeout)
	}
	for {
		if err := ctx.Err(); err != nil {
			cancelOverlapped(handle, ov)
			return err
		}
		if !deadline.IsZero() && time.Now().After(deadline) {
			cancelOverlapped(handle, ov)
			return context.DeadlineExceeded
		}
		wait, err := windows.WaitForSingleObject(ov.HEvent, 100)
		if err != nil {
			cancelOverlapped(handle, ov)
			return err
		}
		if wait == windows.WAIT_OBJECT_0 {
			var done uint32
			return windows.GetOverlappedResult(handle, ov, &done, false)
		}
		if wait != uint32(windows.WAIT_TIMEOUT) {
			cancelOverlapped(handle, ov)
			return fmt.Errorf("unexpected guard pipe wait result %d", wait)
		}
	}
}

func cancelOverlapped(handle windows.Handle, ov *windows.Overlapped) {
	_ = windows.CancelIoEx(handle, ov)
	var done uint32
	_ = windows.GetOverlappedResult(handle, ov, &done, true)
}

func readMessage(ctx context.Context, pipe windows.Handle) ([]byte, error) {
	buffer := make([]byte, pipeBufferSize)
	ov, closeEvent, err := newOverlappedEvent()
	if err != nil {
		return nil, err
	}
	defer closeEvent()
	var done uint32
	err = windows.ReadFile(pipe, buffer, &done, &ov)
	if err == windows.ERROR_IO_PENDING {
		if err = waitOverlapped(ctx, pipe, &ov, requestTimeout); err == nil {
			err = windows.GetOverlappedResult(pipe, &ov, &done, false)
		}
	}
	if err != nil {
		return nil, err
	}
	if done == 0 || done > wfpguard.MaxRequestBytes {
		return nil, errors.New("guard message is empty or oversized")
	}
	return buffer[:done], nil
}

func writeMessage(ctx context.Context, pipe windows.Handle, message []byte) error {
	ov, closeEvent, err := newOverlappedEvent()
	if err != nil {
		return err
	}
	defer closeEvent()
	var done uint32
	err = windows.WriteFile(pipe, message, &done, &ov)
	if err == windows.ERROR_IO_PENDING {
		if err = waitOverlapped(ctx, pipe, &ov, responseTimeout); err == nil {
			err = windows.GetOverlappedResult(pipe, &ov, &done, false)
		}
	}
	if err != nil {
		return err
	}
	if int(done) != len(message) {
		return errors.New("short guard response write")
	}
	return nil
}

type serviceHost struct {
	configuredUserSID string
}

func RunWindowsService(configuredUserSID string) error {
	if _, err := CanonicalUserSID(configuredUserSID); err != nil {
		return err
	}
	return svc.Run(ServiceName, &serviceHost{configuredUserSID: configuredUserSID})
}

func (h *serviceHost) Execute(_ []string, requests <-chan svc.ChangeRequest, statuses chan<- svc.Status) (bool, uint32) {
	statuses <- svc.Status{State: svc.StartPending}
	server, err := NewPipeServer(h.configuredUserSID)
	if err != nil {
		return false, 1
	}
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	finished := make(chan error, 1)
	go func() { finished <- server.Run(ctx) }()
	statuses <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for {
		select {
		case err := <-finished:
			statuses <- svc.Status{State: svc.StopPending}
			if err != nil {
				return false, 1
			}
			return false, 0
		case request, open := <-requests:
			if !open {
				statuses <- svc.Status{State: svc.StopPending}
				cancel()
				if err := <-finished; err != nil {
					return false, 1
				}
				return false, 0
			}
			switch request.Cmd {
			case svc.Stop, svc.Shutdown:
				statuses <- svc.Status{State: svc.StopPending}
				cancel()
				if err := <-finished; err != nil {
					return false, 1
				}
				return false, 0
			case svc.Interrogate:
				statuses <- request.CurrentStatus
			}
		}
	}
}
