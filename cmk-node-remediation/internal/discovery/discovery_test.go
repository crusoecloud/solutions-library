package discovery

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"

	"crusoe-node-remediation/internal/config"
	"crusoe-node-remediation/internal/constants"
	"crusoe-node-remediation/internal/k8s"
)

func TestDiscoverNodes(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-gpu-1",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-001",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
		},
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-gpu-2",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-002",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
		},
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-cpu-1",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-b",
					constants.LabelInstanceID:   "vm-003",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "cpu-4x",
				},
			},
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		InstanceTypeFilter: "b200.*",
		NodeSelector: config.NodeSelectorConfig{
			MatchLabels: map[string]string{
				constants.LabelProjectID: "proj-1",
			},
		},
	}
	discoverer := NewDiscoverer(k8sClient, cfg)

	groups, err := discoverer.Discover(context.Background())
	if err != nil {
		t.Fatalf("Discover failed: %v", err)
	}

	if len(groups) != 1 {
		t.Fatalf("expected 1 node group, got %d", len(groups))
	}
	if groups[0].NodepoolID != "pool-a" {
		t.Errorf("nodepool = %q, want pool-a", groups[0].NodepoolID)
	}
	if len(groups[0].Nodes) != 2 {
		t.Errorf("expected 2 nodes in pool-a, got %d", len(groups[0].Nodes))
	}
}

func TestDiscoverNoNodes(t *testing.T) {
	clientset := fake.NewSimpleClientset()
	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		InstanceTypeFilter: "b200.*",
		NodeSelector: config.NodeSelectorConfig{
			MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"},
		},
	}
	discoverer := NewDiscoverer(k8sClient, cfg)

	groups, err := discoverer.Discover(context.Background())
	if err != nil {
		t.Fatalf("Discover failed: %v", err)
	}

	if len(groups) != 0 {
		t.Errorf("expected 0 groups, got %d", len(groups))
	}
}
