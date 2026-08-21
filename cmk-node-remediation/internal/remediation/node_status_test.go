package remediation

import (
	"context"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"

	"crusoe-node-remediation/internal/config"
	"crusoe-node-remediation/internal/constants"
	"crusoe-node-remediation/internal/discovery"
	"crusoe-node-remediation/internal/guardrails"
	"crusoe-node-remediation/internal/k8s"
)

func TestEvaluateNode_NormalNode(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-1",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-001",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
			Status: corev1.NodeStatus{
				Conditions: []corev1.NodeCondition{
					{Type: corev1.NodeReady, Status: corev1.ConditionTrue},
				},
			},
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:      config.Duration(55 * 24 * time.Hour),
		RemediationThreshold: config.Duration(60 * 24 * time.Hour),
		InstanceTypeFilter:   "b200.*",
		Guardrails:           config.GuardrailsConfig{GlobalMaxCordoned: 5, PerPoolMaxCordoned: 2},
	}

	mgr := NewManager(Dependencies{
		K8sClient:    k8sClient,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -30)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Config:       cfg,
	})

	nodeInfo := discovery.NodeInfo{
		Name:       "node-1",
		InstanceID: "vm-001",
		Node:       getNode(clientset, "node-1"),
	}

	status := mgr.evaluateNode(context.Background(), nodeInfo, "")

	if status.Name != "node-1" {
		t.Errorf("Name = %q, want node-1", status.Name)
	}
	if !status.Ready {
		t.Error("Ready should be true")
	}
	if status.Excluded {
		t.Error("Excluded should be false for normal node")
	}
	if status.Action != ActionNone {
		t.Errorf("Action = %v, want ActionNone (30 days < 55d threshold)", status.Action)
	}
	if status.Uptime == 0 {
		t.Error("Uptime should be non-zero")
	}
}

func TestEvaluateNode_SelfNode(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-self",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-001",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:      config.Duration(55 * 24 * time.Hour),
		RemediationThreshold: config.Duration(60 * 24 * time.Hour),
	}

	mgr := NewManager(Dependencies{
		K8sClient:    k8sClient,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -61)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Config:       cfg,
	})

	nodeInfo := discovery.NodeInfo{
		Name: "node-self",
		Node: getNode(clientset, "node-self"),
	}

	status := mgr.evaluateNode(context.Background(), nodeInfo, "node-self")

	if !status.Excluded {
		t.Error("Excluded should be true for self-node")
	}
	if status.ExcludeReason != ExcludeSelfNode {
		t.Errorf("ExcludeReason = %q, want %q", status.ExcludeReason, ExcludeSelfNode)
	}
}

func TestEvaluateNode_Undetermined(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-fail",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-001",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:      config.Duration(55 * 24 * time.Hour),
		RemediationThreshold: config.Duration(60 * 24 * time.Hour),
	}

	mgr := NewManager(Dependencies{
		K8sClient:    k8sClient,
		UptimeEval:   &mockUptimeEvaluatorFail{failNode: "node-fail", startTime: time.Now()},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Config:       cfg,
	})

	nodeInfo := discovery.NodeInfo{
		Name: "node-fail",
		Node: getNode(clientset, "node-fail"),
	}

	status := mgr.evaluateNode(context.Background(), nodeInfo, "")

	if !status.Excluded {
		t.Error("Excluded should be true for undetermined node")
	}
	if status.ExcludeReason != ExcludeUndetermined {
		t.Errorf("ExcludeReason = %q, want %q", status.ExcludeReason, ExcludeUndetermined)
	}
}

func TestEvaluateNode_InCooldown(t *testing.T) {
	cooldownAgo := time.Now().AddDate(0, 0, -3).Format(time.RFC3339)

	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-cooldown",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-001",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
				Annotations: map[string]string{
					constants.AnnotationActionCompletedAt: cooldownAgo,
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:      config.Duration(55 * 24 * time.Hour),
		RemediationThreshold: config.Duration(60 * 24 * time.Hour),
		RemediationCooldown:  config.Duration(7 * 24 * time.Hour),
	}

	mgr := NewManager(Dependencies{
		K8sClient:    k8sClient,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -61)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Config:       cfg,
	})

	nodeInfo := discovery.NodeInfo{
		Name: "node-cooldown",
		Node: getNode(clientset, "node-cooldown"),
	}

	status := mgr.evaluateNode(context.Background(), nodeInfo, "")

	if !status.Excluded {
		t.Error("Excluded should be true for node in cooldown")
	}
	if status.ExcludeReason != ExcludeCooldown {
		t.Errorf("ExcludeReason = %q, want %q", status.ExcludeReason, ExcludeCooldown)
	}
	if !status.InCooldown {
		t.Error("InCooldown should be true")
	}
}

func TestEvaluateNode_CordonAction(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-56d",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-001",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:      config.Duration(55 * 24 * time.Hour),
		RemediationThreshold: config.Duration(60 * 24 * time.Hour),
	}

	mgr := NewManager(Dependencies{
		K8sClient:    k8sClient,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -56)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Config:       cfg,
	})

	nodeInfo := discovery.NodeInfo{
		Name: "node-56d",
		Node: getNode(clientset, "node-56d"),
	}

	status := mgr.evaluateNode(context.Background(), nodeInfo, "")

	if status.Action != ActionCordon {
		t.Errorf("Action = %v, want ActionCordon (56d >= 55d cordon threshold)", status.Action)
	}
	if status.Excluded {
		t.Error("Excluded should be false for cordon-action node")
	}
}

func TestEvaluateNode_RemediateAction(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-61d",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-001",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:      config.Duration(55 * 24 * time.Hour),
		RemediationThreshold: config.Duration(60 * 24 * time.Hour),
	}

	mgr := NewManager(Dependencies{
		K8sClient:    k8sClient,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -61)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Config:       cfg,
	})

	nodeInfo := discovery.NodeInfo{
		Name: "node-61d",
		Node: getNode(clientset, "node-61d"),
	}

	status := mgr.evaluateNode(context.Background(), nodeInfo, "")

	if status.Action != ActionRemediate {
		t.Errorf("Action = %v, want ActionRemediate (61d >= 60d remediation threshold)", status.Action)
	}
}

func TestEvaluateNode_ManagedLabel(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-managed",
				Labels: map[string]string{
					constants.LabelNodepoolID:         "pool-a",
					constants.LabelInstanceID:         "vm-001",
					constants.LabelProjectID:          "proj-1",
					constants.LabelInstanceType:       "b200-180gb-sxm-ib.8x",
					constants.LabelRemediationManaged: "true",
					constants.LabelRemediationPhase:   string(constants.PhaseCordoned),
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: true},
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:      config.Duration(55 * 24 * time.Hour),
		RemediationThreshold: config.Duration(60 * 24 * time.Hour),
	}

	mgr := NewManager(Dependencies{
		K8sClient:    k8sClient,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -30)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Config:       cfg,
	})

	nodeInfo := discovery.NodeInfo{
		Name: "node-managed",
		Node: getNode(clientset, "node-managed"),
	}

	status := mgr.evaluateNode(context.Background(), nodeInfo, "")

	if !status.Managed {
		t.Error("Managed should be true when label is set")
	}
	if status.Phase != constants.PhaseCordoned {
		t.Errorf("Phase = %v, want %v", status.Phase, constants.PhaseCordoned)
	}
}

// getNode is a test helper that fetches a node from the fake clientset.
func getNode(clientset *fake.Clientset, name string) *corev1.Node {
	node, _ := clientset.CoreV1().Nodes().Get(context.Background(), name, metav1.GetOptions{})
	return node
}
