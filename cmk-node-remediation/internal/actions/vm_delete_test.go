package actions

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"crusoe-node-remediation/internal/crusoe"
	"crusoe-node-remediation/internal/k8s"

	"k8s.io/client-go/kubernetes/fake"
)

// mockSwaggerError implements the crusoe.swaggerError interface for testing.
type mockSwaggerError struct {
	msg  string
	body []byte
}

func (e *mockSwaggerError) Error() string { return e.msg }
func (e *mockSwaggerError) Body() []byte  { return e.body }

func TestIsNotFoundError(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want bool
	}{
		{
			name: "404 in error message",
			err:  &mockSwaggerError{msg: "404 Not Found", body: []byte(`{"error":"instance not found"}`)},
			want: true,
		},
		{
			name: "404 in body",
			err:  &mockSwaggerError{msg: "error", body: []byte(`{"error":"instance not found"}`)},
			want: true,
		},
		{
			name: "not found in body (case insensitive)",
			err:  &mockSwaggerError{msg: "error", body: []byte(`{"error":"Instance Not Found"}`)},
			want: true,
		},
		{
			name: "500 error",
			err:  &mockSwaggerError{msg: "500 Internal Server Error", body: []byte(`{"error":"internal error"}`)},
			want: false,
		},
		{
			name: "401 error",
			err:  &mockSwaggerError{msg: "401 Unauthorized", body: []byte(`{"error":"invalid token"}`)},
			want: false,
		},
		{
			name: "generic error (not swagger)",
			err:  fmt.Errorf("connection refused"),
			want: false,
		},
		{
			name: "nil error",
			err:  nil,
			want: false,
		},
		{
			name: "wrapped 404",
			err:  fmt.Errorf("get VM state: %w", &mockSwaggerError{msg: "404 Not Found"}),
			want: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := crusoe.IsNotFoundError(tt.err)
			if got != tt.want {
				t.Errorf("crusoe.IsNotFoundError(%v) = %v, want %v", tt.err, got, tt.want)
			}
		})
	}
}

func TestIsNotFoundErrorWrapped(t *testing.T) {
	// Verify errors.As unwraps correctly
	inner := &mockSwaggerError{msg: "404 Not Found"}
	wrapped := fmt.Errorf("Crusoe API GetInstance failed for VM vm-123: %w", inner)

	if !crusoe.IsNotFoundError(wrapped) {
		t.Error("crusoe.IsNotFoundError should unwrap wrapped errors")
	}

	// Verify non-swagger errors don't match
	plainErr := errors.New("404 Not Found")
	if crusoe.IsNotFoundError(plainErr) {
		t.Error("crusoe.IsNotFoundError should not match non-swagger errors")
	}
}

func TestVMDeleteSkipsWhenAlreadyGone(t *testing.T) {
	f := newFakeCrusoeServer(t)
	f.setVMState("") // empty state -> fake returns 404
	k8sClient := k8s.NewClient(fake.NewSimpleClientset(), nil)

	step := &VMDeleteStep{
		crusoeClient: f.client(),
		k8sClient:    k8sClient,
		timeout:      500 * time.Millisecond,
		maxRetries:   2,
	}

	err := step.Run(context.Background(), NodeInfo{Name: "node-1", InstanceID: "vm-001"}, nil)
	if err != nil {
		t.Fatalf("Run failed: %v", err)
	}
	if got := f.calls(); len(got) != 0 {
		t.Errorf("expected no API action calls, got %v", got)
	}
}

func TestVMDeleteDeletesExistingVM(t *testing.T) {
	f := newFakeCrusoeServer(t)
	f.setVMState("STATE_RUNNING")
	k8sClient := k8s.NewClient(fake.NewSimpleClientset(), nil)

	step := &VMDeleteStep{
		crusoeClient: f.client(),
		k8sClient:    k8sClient,
		timeout:      500 * time.Millisecond,
		maxRetries:   2,
	}

	// The fake flips to 404 synchronously on DELETE, so the post-delete
	// existence check sees the VM as gone immediately.
	err := step.Run(context.Background(), NodeInfo{Name: "node-1", InstanceID: "vm-001"}, nil)
	if err != nil {
		t.Fatalf("Run failed: %v", err)
	}
	calls := f.calls()
	if len(calls) != 1 || calls[0] != "DELETE" {
		t.Errorf("expected one DELETE call, got %v", calls)
	}
}

func TestVMDeleteRetriesOnAPIError(t *testing.T) {
	f := newFakeCrusoeServer(t)
	f.setVMState("STATE_RUNNING")
	f.setActionErrStatus(500)
	k8sClient := k8s.NewClient(fake.NewSimpleClientset(), nil)

	step := &VMDeleteStep{
		crusoeClient: f.client(),
		k8sClient:    k8sClient,
		timeout:      500 * time.Millisecond,
		maxRetries:   2,
	}

	err := step.Run(context.Background(), NodeInfo{Name: "node-1", InstanceID: "vm-001"}, nil)
	if err == nil {
		t.Fatal("expected error after retries exhausted")
	}
	if !strings.Contains(err.Error(), "vm-delete failed after 2 attempts") {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestVMDeleteType(t *testing.T) {
	step := &VMDeleteStep{}
	if step.Type() != "vm-delete" {
		t.Errorf("Type() = %q, want vm-delete", step.Type())
	}
}
