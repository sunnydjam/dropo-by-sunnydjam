package wfpguard

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
)

const (
	ProtocolVersion uint16    = 1
	MaxRequestBytes           = 32 * 1024
	OperationStatus Operation = "status"
	OperationArm    Operation = "arm"
	OperationDisarm Operation = "disarm"
)

// Operation is a closed command set. Raw WFP filters, arbitrary executable
// paths, and shell commands cannot be expressed through this protocol.
type Operation string

// Request is one bounded, one-shot IPC message. Authentication and matching
// Policy.UserSID against the caller token are responsibilities of the future
// Windows service; passing Validate does not authorize or apply any filter.
type Request struct {
	Version          uint16    `json:"version"`
	Operation        Operation `json:"operation"`
	ExpectedRevision uint64    `json:"expectedRevision,omitempty"`
	Policy           *Policy   `json:"policy,omitempty"`
}

func (r Request) Validate() error {
	if r.Version != ProtocolVersion {
		return fmt.Errorf("unsupported guard protocol version %d", r.Version)
	}
	switch r.Operation {
	case OperationStatus:
		if r.Policy != nil || r.ExpectedRevision != 0 {
			return errors.New("status request must not mutate policy")
		}
	case OperationArm:
		if r.Policy == nil {
			return errors.New("arm request requires a policy")
		}
		if r.Policy.Revision <= r.ExpectedRevision {
			return errors.New("arm revision must advance the expected revision")
		}
		if err := r.Policy.Validate(); err != nil {
			return fmt.Errorf("arm policy: %w", err)
		}
	case OperationDisarm:
		if r.Policy != nil || r.ExpectedRevision == 0 {
			return errors.New("disarm request requires only a nonzero expected revision")
		}
	default:
		return errors.New("unknown guard operation")
	}
	return nil
}

// DecodeRequest rejects oversized, ambiguous or extended messages before
// service code can interpret them. The caller must use one request per IPC
// connection and close its writing side; the service must also bound the read
// deadline so a client cannot hold an administrative worker indefinitely.
func DecodeRequest(reader io.Reader) (Request, error) {
	data, err := io.ReadAll(io.LimitReader(reader, MaxRequestBytes+1))
	if err != nil {
		return Request{}, fmt.Errorf("read guard request: %w", err)
	}
	if len(data) == 0 || len(data) > MaxRequestBytes {
		return Request{}, errors.New("guard request is empty or exceeds its byte limit")
	}
	if err := rejectDuplicateJSONKeys(json.NewDecoder(bytes.NewReader(data)), 0); err != nil {
		return Request{}, fmt.Errorf("guard request is ambiguous: %w", err)
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var request Request
	if err := decoder.Decode(&request); err != nil {
		return Request{}, fmt.Errorf("decode guard request: %w", err)
	}
	var extra interface{}
	if err := decoder.Decode(&extra); err != io.EOF {
		return Request{}, errors.New("guard request has trailing data")
	}
	if err := request.Validate(); err != nil {
		return Request{}, err
	}
	return request, nil
}

func rejectDuplicateJSONKeys(decoder *json.Decoder, depth int) error {
	if depth > 16 {
		return errors.New("JSON nesting exceeds the guard protocol limit")
	}
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	delim, ok := token.(json.Delim)
	if !ok {
		return nil
	}
	switch delim {
	case '{':
		seen := make(map[string]struct{})
		for decoder.More() {
			keyToken, err := decoder.Token()
			if err != nil {
				return err
			}
			key, ok := keyToken.(string)
			if !ok {
				return errors.New("object key is not a string")
			}
			folded := strings.ToLower(key)
			if _, duplicate := seen[folded]; duplicate {
				return fmt.Errorf("duplicate JSON key %q", key)
			}
			seen[folded] = struct{}{}
			if err := rejectDuplicateJSONKeys(decoder, depth+1); err != nil {
				return err
			}
		}
	case '[':
		for decoder.More() {
			if err := rejectDuplicateJSONKeys(decoder, depth+1); err != nil {
				return err
			}
		}
	default:
		return errors.New("unexpected JSON delimiter")
	}
	_, err = decoder.Token()
	return err
}
