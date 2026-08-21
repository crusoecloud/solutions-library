package actions

import (
	"context"
	"strings"
	"testing"
	"time"

	"k8s.io/client-go/kubernetes/fake"

	"crusoe-node-remediation/internal/actions/helpers"
	"crusoe-node-remediation/internal/k8s"
)

// Note: the happy path (RESET → bootID changes → Ready) can't be tested with
// the k8s fake clientset because it doesn't persist status updates. The boot
// verification logic itself is covered by boot_verifier_test.go.
func TestVMResetCallsResetAPI(t *testing.T) {
	f := newFakeCrusoeServer(t)
	k8sClient := k8s.NewClient(fake.NewSimpleClientset(readyNode("node-1", "boot-1")), nil)

	step := &VMResetStep{
		crusoeClient: f.client(),
		k8sClient:    k8sClient,
		bootVerifier: helpers.NewBootVerifier(k8sClient),
		timeout:      100 * time.Millisecond, // short — boot verify will timeout
		maxRetries:   1,
	}

	// We expect failure (bootID never changes in the k8s fake), but the RESET
	// API call should have been made exactly once.
	_ = step.Run(context.Background(), NodeInfo{Name: "node-1", InstanceID: "vm-001"}, nil)
	calls := f.calls()
	if len(calls) != 1 || calls[0] != "RESET" {
		t.Errorf("expected one RESET call, got %v", calls)
	}
}

func TestVMResetRetriesOnAPIError(t *testing.T) {
	f := newFakeCrusoeServer(t)
	f.setActionErrStatus(500)
	k8sClient := k8s.NewClient(fake.NewSimpleClientset(readyNode("node-1", "boot-1")), nil)

	step := &VMResetStep{
		crusoeClient: f.client(),
		k8sClient:    k8sClient,
		bootVerifier: helpers.NewBootVerifier(k8sClient),
		timeout:      500 * time.Millisecond,
		maxRetries:   2,
	}

	err := step.Run(context.Background(), NodeInfo{Name: "node-1", InstanceID: "vm-001"}, nil)
	if err == nil {
		t.Fatal("expected error after retries exhausted")
	}
	if !strings.Contains(err.Error(), "vm-reset failed after 2 attempts") {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestVMResetFailsWhenNodeMissing(t *testing.T) {
	f := newFakeCrusoeServer(t)
	// No node in the cluster — GetNode fails before any API call.
	k8sClient := k8s.NewClient(fake.NewSimpleClientset(), nil)

	step := &VMResetStep{
		crusoeClient: f.client(),
		k8sClient:    k8sClient,
		bootVerifier: helpers.NewBootVerifier(k8sClient),
		timeout:      500 * time.Millisecond,
		maxRetries:   2,
	}

	err := step.Run(context.Background(), NodeInfo{Name: "node-1", InstanceID: "vm-001"}, nil)
	if err == nil {
		t.Fatal("expected error when node is missing")
	}
	if !strings.Contains(err.Error(), "failed to get node") {
		t.Errorf("unexpected error: %v", err)
	}
	if got := f.calls(); len(got) != 0 {
		t.Errorf("expected no API action calls, got %v", got)
	}
}

func TestVMResetType(t *testing.T) {
	step := &VMResetStep{}
	if step.Type() != "vm-reset" {
		t.Errorf("Type() = %q, want vm-reset", step.Type())
	}
}
