package actions

import (
	"context"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"

	"crusoe-node-remediation/internal/actions/helpers"
	"crusoe-node-remediation/internal/k8s"
)

func readyNode(name, bootID string) *corev1.Node {
	return &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Status: corev1.NodeStatus{
			NodeInfo: corev1.NodeSystemInfo{BootID: bootID},
			Conditions: []corev1.NodeCondition{
				{Type: corev1.NodeReady, Status: corev1.ConditionTrue},
			},
		},
	}
}

func TestVMStartSkipsWhenAlreadyRunningAndReady(t *testing.T) {
	f := newFakeCrusoeServer(t) // default state: STATE_RUNNING
	k8sClient := k8s.NewClient(fake.NewSimpleClientset(readyNode("node-1", "boot-1")), nil)

	step := &VMStartStep{
		crusoeClient: f.client(),
		k8sClient:    k8sClient,
		bootVerifier: helpers.NewBootVerifier(k8sClient),
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

func TestVMStartStartsStoppedVM(t *testing.T) {
	f := newFakeCrusoeServer(t)
	f.setVMState("STATE_STOPPED")
	k8sClient := k8s.NewClient(fake.NewSimpleClientset(readyNode("node-1", "boot-1")), nil)

	step := &VMStartStep{
		crusoeClient: f.client(),
		k8sClient:    k8sClient,
		bootVerifier: helpers.NewBootVerifier(k8sClient),
		timeout:      500 * time.Millisecond,
		maxRetries:   2,
	}

	err := step.Run(context.Background(), NodeInfo{Name: "node-1", InstanceID: "vm-001"}, nil)
	if err != nil {
		t.Fatalf("Run failed: %v", err)
	}
	calls := f.calls()
	if len(calls) != 1 || calls[0] != "START" {
		t.Errorf("expected one START call, got %v", calls)
	}
}

func TestVMStartRetriesOnAPIError(t *testing.T) {
	f := newFakeCrusoeServer(t)
	f.setVMState("STATE_STOPPED")
	f.setActionErrStatus(500) // PATCH always fails
	k8sClient := k8s.NewClient(fake.NewSimpleClientset(readyNode("node-1", "boot-1")), nil)

	step := &VMStartStep{
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
	if !strings.Contains(err.Error(), "vm-start failed after 2 attempts") {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestVMStartType(t *testing.T) {
	step := &VMStartStep{}
	if step.Type() != "vm-start" {
		t.Errorf("Type() = %q, want vm-start", step.Type())
	}
}
