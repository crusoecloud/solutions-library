package actions

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestVMStopSkipsWhenAlreadyStopped(t *testing.T) {
	f := newFakeCrusoeServer(t)
	f.setVMState("STATE_STOPPED")

	step := &VMStopStep{
		crusoeClient: f.client(),
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

func TestVMStopStopsRunningVM(t *testing.T) {
	f := newFakeCrusoeServer(t)
	// VM reports RUNNING for the idempotency check; the fake server
	// transitions to STOPPED synchronously when it receives the STOP action.
	f.setVMState("STATE_RUNNING")

	step := &VMStopStep{
		crusoeClient: f.client(),
		timeout:      500 * time.Millisecond,
		maxRetries:   2,
	}

	err := step.Run(context.Background(), NodeInfo{Name: "node-1", InstanceID: "vm-001"}, nil)
	if err != nil {
		t.Fatalf("Run failed: %v", err)
	}
	calls := f.calls()
	if len(calls) != 1 || calls[0] != "STOP" {
		t.Errorf("expected one STOP call, got %v", calls)
	}
}

func TestVMStopRetriesOnAPIError(t *testing.T) {
	f := newFakeCrusoeServer(t)
	f.setVMState("STATE_RUNNING")
	f.setActionErrStatus(500)

	step := &VMStopStep{
		crusoeClient: f.client(),
		timeout:      500 * time.Millisecond,
		maxRetries:   2,
	}

	err := step.Run(context.Background(), NodeInfo{Name: "node-1", InstanceID: "vm-001"}, nil)
	if err == nil {
		t.Fatal("expected error after retries exhausted")
	}
	if !strings.Contains(err.Error(), "vm-stop failed after 2 attempts") {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestVMStopType(t *testing.T) {
	step := &VMStopStep{}
	if step.Type() != "vm-stop" {
		t.Errorf("Type() = %q, want vm-stop", step.Type())
	}
}
