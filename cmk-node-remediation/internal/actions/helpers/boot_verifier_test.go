package helpers

import (
	"context"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"

	"crusoe-node-remediation/internal/k8s"
)

func TestCaptureBootID(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{Name: "node-1"},
			Status: corev1.NodeStatus{
				NodeInfo: corev1.NodeSystemInfo{BootID: "boot-abc"},
			},
		},
	)
	bv := NewBootVerifier(k8s.NewClient(clientset, nil))

	bootID, err := bv.CaptureBootID(context.Background(), "node-1")
	if err != nil {
		t.Fatalf("CaptureBootID failed: %v", err)
	}
	if bootID != "boot-abc" {
		t.Errorf("bootID = %q, want boot-abc", bootID)
	}
}

func TestVerifyBootDetectsChange(t *testing.T) {
	// Node starts with bootID "old-boot", then we update it to "new-boot"
	// Use Update (not UpdateStatus) since fake clientset doesn't persist status subresource
	// Note: fake clientset's Update() doesn't preserve Status changes across Get() calls.
	// We need to use a custom approach: create the node with the "new" bootID from the start,
	// and have the verifier check against the "old" value.
	// Instead, test the core logic: if bootID differs, VerifyBoot returns it.
	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{Name: "node-1"},
			Status: corev1.NodeStatus{
				NodeInfo: corev1.NodeSystemInfo{BootID: "new-boot"},
			},
		},
	)
	bv := NewBootVerifier(k8s.NewClient(clientset, nil))

	// bootID is already "new-boot", oldBootID is "old-boot" — should detect immediately
	newBootID, err := bv.VerifyBoot(context.Background(), "node-1", "old-boot", 5*time.Second)
	if err != nil {
		t.Fatalf("VerifyBoot failed: %v", err)
	}
	if newBootID != "new-boot" {
		t.Errorf("newBootID = %q, want new-boot", newBootID)
	}
}

func TestVerifyBootTimeout(t *testing.T) {
	// bootID never changes — should timeout
	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{Name: "node-1"},
			Status: corev1.NodeStatus{
				NodeInfo: corev1.NodeSystemInfo{BootID: "same-boot"},
			},
		},
	)
	bv := NewBootVerifier(k8s.NewClient(clientset, nil))

	_, err := bv.VerifyBoot(context.Background(), "node-1", "same-boot", 200*time.Millisecond)
	if err == nil {
		t.Fatal("VerifyBoot should timeout when bootID doesn't change")
	}
}

func TestVerifyBootAndReady(t *testing.T) {
	// Node is already Ready with new bootID — should pass immediately
	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{Name: "node-1"},
			Status: corev1.NodeStatus{
				NodeInfo: corev1.NodeSystemInfo{BootID: "new-boot"},
				Conditions: []corev1.NodeCondition{
					{Type: corev1.NodeReady, Status: corev1.ConditionTrue},
				},
			},
		},
	)
	bv := NewBootVerifier(k8s.NewClient(clientset, nil))

	err := bv.VerifyBootAndReady(context.Background(), "node-1", "old-boot", 5*time.Second)
	if err != nil {
		t.Fatalf("VerifyBootAndReady failed: %v", err)
	}
}

func TestVerifyBootAndReadyNotReady(t *testing.T) {
	// bootID changed but node is NOT Ready — should timeout
	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{Name: "node-1"},
			Status: corev1.NodeStatus{
				NodeInfo: corev1.NodeSystemInfo{BootID: "new-boot"},
				Conditions: []corev1.NodeCondition{
					{Type: corev1.NodeReady, Status: corev1.ConditionFalse},
				},
			},
		},
	)
	bv := NewBootVerifier(k8s.NewClient(clientset, nil))

	err := bv.VerifyBootAndReady(context.Background(), "node-1", "old-boot", 500*time.Millisecond)
	if err == nil {
		t.Fatal("VerifyBootAndReady should timeout when node is not Ready")
	}
}
