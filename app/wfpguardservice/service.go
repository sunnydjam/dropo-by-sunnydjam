// Package wfpguardservice hosts the future Windows WFP guard. This stage is
// deliberately non-activating: no request can claim or establish protection.
package wfpguardservice

import (
	"errors"
	"fmt"

	"dropo/wfpguard"
)

const ServiceName = "DropoWFPGuard"

var (
	ErrUnauthorized  = errors.New("guard caller is not the configured user")
	ErrStaleRevision = errors.New("guard policy revision is stale")
	ErrNotIntegrated = errors.New("WFP guard activation is not integrated")
)

// Response is intentionally separate from the app's VPN protection status.
// In particular, a running service is not an active kill switch.
type Response struct {
	Version          uint16 `json:"version"`
	ProtectionActive bool   `json:"protectionActive"`
	State            string `json:"state"`
	Revision         uint64 `json:"revision"`
	Error            string `json:"error,omitempty"`
}

// Handler is bound to one installer-selected user SID. Its revision is always
// zero until atomic WFP installation and readback are implemented.
type Handler struct {
	allowedUserSID string
}

func NewHandler(allowedUserSID string) (*Handler, error) {
	if allowedUserSID == "" {
		return nil, errors.New("configured user SID is required")
	}
	return &Handler{allowedUserSID: allowedUserSID}, nil
}

// Handle checks the OS-authenticated caller SID separately from the policy
// payload. The Windows pipe transport must obtain callerSID from the client's
// impersonation token after reading that same client's request message.
func (h *Handler) Handle(callerSID string, request wfpguard.Request) Response {
	response := Response{
		Version:          wfpguard.ProtocolVersion,
		ProtectionActive: false,
		State:            "not_integrated",
		Revision:         0,
	}
	if h == nil || callerSID == "" || callerSID != h.allowedUserSID {
		response.Error = ErrUnauthorized.Error()
		return response
	}
	if err := request.Validate(); err != nil {
		response.Error = fmt.Sprintf("invalid request: %v", err)
		return response
	}
	if request.Operation == wfpguard.OperationArm && request.Policy.UserSID != callerSID {
		response.Error = ErrUnauthorized.Error()
		return response
	}
	if request.Operation != wfpguard.OperationStatus && request.ExpectedRevision != response.Revision {
		response.Error = ErrStaleRevision.Error()
		return response
	}
	if request.Operation != wfpguard.OperationStatus {
		response.Error = ErrNotIntegrated.Error()
	}
	return response
}
