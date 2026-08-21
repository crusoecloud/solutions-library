package k8s

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func TestCordon(t *testing.T) {
	clientset := fake.NewSimpleClientset(&corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: "node-1"},
		Spec:       corev1.NodeSpec{Unschedulable: false},
	})
	client := NewClient(clientset, nil)

	if err := client.Cordon(context.Background(), "node-1"); err != nil {
		t.Fatalf("Cordon failed: %v", err)
	}

	node, _ := client.GetNode(context.Background(), "node-1")
	if !node.Spec.Unschedulable {
		t.Error("node should be cordoned")
	}
}

func TestUncordon(t *testing.T) {
	clientset := fake.NewSimpleClientset(&corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: "node-1"},
		Spec:       corev1.NodeSpec{Unschedulable: true},
	})
	client := NewClient(clientset, nil)

	if err := client.Uncordon(context.Background(), "node-1"); err != nil {
		t.Fatalf("Uncordon failed: %v", err)
	}

	node, _ := client.GetNode(context.Background(), "node-1")
	if node.Spec.Unschedulable {
		t.Error("node should be uncordoned")
	}
}

func TestSetLabel(t *testing.T) {
	clientset := fake.NewSimpleClientset(&corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: "node-1"},
	})
	client := NewClient(clientset, nil)

	if err := client.SetLabel(context.Background(), "node-1", "crusoe.ai/remediation.phase", "cordoned"); err != nil {
		t.Fatalf("SetLabel failed: %v", err)
	}

	node, _ := client.GetNode(context.Background(), "node-1")
	if node.Labels["crusoe.ai/remediation.phase"] != "cordoned" {
		t.Errorf("label = %q, want cordoned", node.Labels["crusoe.ai/remediation.phase"])
	}
}

func TestSetAnnotation(t *testing.T) {
	clientset := fake.NewSimpleClientset(&corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: "node-1"},
	})
	client := NewClient(clientset, nil)

	if err := client.SetAnnotation(context.Background(), "node-1", "crusoe.ai/remediation.cordoned-at", "2026-08-07T14:44:00Z"); err != nil {
		t.Fatalf("SetAnnotation failed: %v", err)
	}

	node, _ := client.GetNode(context.Background(), "node-1")
	if node.Annotations["crusoe.ai/remediation.cordoned-at"] != "2026-08-07T14:44:00Z" {
		t.Errorf("annotation = %q, want 2026-08-07T14:44:00Z", node.Annotations["crusoe.ai/remediation.cordoned-at"])
	}
}

func TestAddAndRemoveTaint(t *testing.T) {
	clientset := fake.NewSimpleClientset(&corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: "node-1"},
		Spec:       corev1.NodeSpec{Taints: []corev1.Taint{}},
	})
	client := NewClient(clientset, nil)

	if err := client.AddTaint(context.Background(), "node-1", "crusoe.ai/remediation.scheduled"); err != nil {
		t.Fatalf("AddTaint failed: %v", err)
	}

	node, _ := client.GetNode(context.Background(), "node-1")
	if !HasTaint(node, "crusoe.ai/remediation.scheduled") {
		t.Error("taint should be present")
	}

	if err := client.RemoveTaint(context.Background(), "node-1", "crusoe.ai/remediation.scheduled"); err != nil {
		t.Fatalf("RemoveTaint failed: %v", err)
	}

	node, _ = client.GetNode(context.Background(), "node-1")
	if HasTaint(node, "crusoe.ai/remediation.scheduled") {
		t.Error("taint should be absent")
	}
}

func TestIsCordoned(t *testing.T) {
	cordoned := &corev1.Node{Spec: corev1.NodeSpec{Unschedulable: true}}
	uncordoned := &corev1.Node{Spec: corev1.NodeSpec{Unschedulable: false}}

	if !IsCordoned(cordoned) {
		t.Error("IsCordoned(cordoned) = false, want true")
	}
	if IsCordoned(uncordoned) {
		t.Error("IsCordoned(uncordoned) = true, want false")
	}
}

func TestHasTaint(t *testing.T) {
	node := &corev1.Node{
		Spec: corev1.NodeSpec{
			Taints: []corev1.Taint{
				{Key: "crusoe.ai/remediation.scheduled", Effect: corev1.TaintEffectNoSchedule},
			},
		},
	}

	if !HasTaint(node, "crusoe.ai/remediation.scheduled") {
		t.Error("HasTaint should return true for present taint")
	}
	if HasTaint(node, "crusoe.ai/remediation.draining") {
		t.Error("HasTaint should return false for absent taint")
	}
}

func TestListNodes(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name:   "node-1",
				Labels: map[string]string{"crusoe.ai/remediation.managed": "true"},
			},
		},
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name:   "node-2",
				Labels: map[string]string{},
			},
		},
	)
	client := NewClient(clientset, nil)

	nodes, err := client.ListNodes(context.Background(), "crusoe.ai/remediation.managed=true")
	if err != nil {
		t.Fatalf("ListNodes failed: %v", err)
	}

	if len(nodes.Items) != 1 {
		t.Fatalf("expected 1 node, got %d", len(nodes.Items))
	}
	if nodes.Items[0].Name != "node-1" {
		t.Errorf("got node %q, want node-1", nodes.Items[0].Name)
	}
}

func TestIsNodeReady(t *testing.T) {
	ready := &corev1.Node{
		Status: corev1.NodeStatus{
			Conditions: []corev1.NodeCondition{
				{Type: corev1.NodeReady, Status: corev1.ConditionTrue},
			},
		},
	}
	notReady := &corev1.Node{
		Status: corev1.NodeStatus{
			Conditions: []corev1.NodeCondition{
				{Type: corev1.NodeReady, Status: corev1.ConditionFalse},
			},
		},
	}

	if !IsNodeReady(ready) {
		t.Error("IsNodeReady(ready) = false, want true")
	}
	if IsNodeReady(notReady) {
		t.Error("IsNodeReady(notReady) = true, want false")
	}
}
