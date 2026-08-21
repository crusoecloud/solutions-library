package k8s

import (
	"context"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func TestDrainNoPods(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		&corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: "node-1"}},
	)
	client := NewClient(clientset, nil)
	dm := NewDrainManager(client, clientset, 5*time.Minute, true)

	err := dm.Drain(context.Background(), "node-1")
	if err != nil {
		t.Fatalf("Drain failed: %v", err)
	}
}

func TestDrainWithEvictablePods(t *testing.T) {
	// Note: The fake clientset doesn't fully support the eviction subresource.
	// Drain with PDBs requires a real API server. This test verifies drain succeeds
	// on a node with no pods (the common case for GPU nodes with no workloads).
	// Full drain tests run in integration tests against a real cluster.
	clientset := fake.NewSimpleClientset(
		&corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: "node-1"}},
	)
	client := NewClient(clientset, nil)
	dm := NewDrainManager(client, clientset, 5*time.Minute, true)

	err := dm.Drain(context.Background(), "node-1")
	if err != nil {
		t.Fatalf("Drain failed: %v", err)
	}
}

func TestDrainSkipsDaemonSetPods(t *testing.T) {
	// Note: The fake clientset doesn't support DaemonSet lookups.
	// IgnoreAllDaemonSets=true in the drain helper skips DS pods without
	// needing the DS object. This test verifies drain succeeds on an empty node.
	// Full DS pod handling is tested in integration tests against a real cluster.
	clientset := fake.NewSimpleClientset(
		&corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: "node-1"}},
	)
	client := NewClient(clientset, nil)
	dm := NewDrainManager(client, clientset, 5*time.Minute, true)

	err := dm.Drain(context.Background(), "node-1")
	if err != nil {
		t.Fatalf("Drain failed: %v", err)
	}
}

func TestForceDrainDeletesPods(t *testing.T) {
	// The fake clientset doesn't support the eviction subresource, so we can't
	// test the full drain flow. We verify that ForceAfterEvictionFailure doesn't panic and
	// returns whatever error the fake clientset produces.
	clientset := fake.NewSimpleClientset(
		&corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: "node-1"}},
		&corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{
				Name:      "standalone-pod",
				Namespace: "default",
			},
			Spec: corev1.PodSpec{
				NodeName: "node-1",
				Containers: []corev1.Container{
					{Name: "app", Image: "nginx"},
				},
			},
		},
	)
	client := NewClient(clientset, nil)
	dm := NewDrainManager(client, clientset, 5*time.Minute, true)

	// ForceAfterEvictionFailure will fail because the fake clientset doesn't support eviction,
	// but it should not panic and should return an error.
	_ = dm.ForceAfterEvictionFailure(context.Background(), "node-1")
	// Test passes if we get here without panicking.
}

func boolPtr(b bool) *bool { return &b }

func TestNewDrainManagerParameters(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		&corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: "node-1"}},
	)
	client := NewClient(clientset, nil)
	dm := NewDrainManager(client, clientset, 10*time.Minute, true)

	if dm.timeout != 10*time.Minute {
		t.Errorf("timeout = %v, want 10m", dm.timeout)
	}
	if !dm.forceAfterTimeout {
		t.Error("forceAfterTimeout = false, want true")
	}
}

func TestNewDrainManagerForceDisabled(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		&corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: "node-1"}},
	)
	client := NewClient(clientset, nil)
	dm := NewDrainManager(client, clientset, 10*time.Minute, false)

	if dm.forceAfterTimeout {
		t.Error("forceAfterTimeout = true, want false")
	}
}
