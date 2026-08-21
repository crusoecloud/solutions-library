package remediation

import (
	"context"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
	"k8s.io/client-go/tools/record"

	"crusoe-node-remediation/internal/actions"
	"crusoe-node-remediation/internal/config"
	"crusoe-node-remediation/internal/constants"
	"crusoe-node-remediation/internal/crusoe"
	"crusoe-node-remediation/internal/discovery"
	"crusoe-node-remediation/internal/guardrails"
	"crusoe-node-remediation/internal/k8s"
)

func TestIntegrationFullRemediationWorkflow(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-b200-1",
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
		CordonThreshold:           config.Duration(55 * 24 * time.Hour),
		RemediationThreshold:      config.Duration(60 * 24 * time.Hour),
		DryRun:                    false,
		InstanceTypeFilter:        "b200.*",
		Action:                    config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 3},
		Guardrails:                config.GuardrailsConfig{GlobalMaxCordoned: 5, PerPoolMaxCordoned: 2},
		DrainTimeout:              1 * time.Second,
		ForceAfterEvictionFailure: true,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	crusoeClient := crusoe.NewClient("http://localhost:9999", "test-access", "test-secret", "proj-1")
	stepFactory := actions.NewFactory(k8sClient, crusoeClient)

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     k8s.NewDrainManager(k8sClient, clientset, cfg.DrainTimeout, true),
		StepFactory:  stepFactory,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -61)}, // 61 days ago
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Discoverer:   discovery.NewDiscoverer(k8sClient, cfg),
		Config:       cfg,
		Recorder:     record.NewFakeRecorder(20),
		ReportWriter: nil,
	}

	mgr := NewManager(deps)

	_, err := mgr.Run(context.Background())
	if err != nil {
		t.Fatalf("Run failed: %v", err)
	}

	node, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-b200-1", metav1.GetOptions{})

	// With noop action, node should be uncordoned and back to monitored
	if node.Spec.Unschedulable {
		t.Error("node should be uncordoned after successful noop remediation")
	}
	if node.Labels[constants.LabelRemediationManaged] != "true" {
		t.Error("node should have remediation.managed=true label")
	}
	if node.Labels[constants.LabelRemediationPhase] != string(constants.PhaseMonitored) {
		t.Errorf("phase = %q, want %q", node.Labels[constants.LabelRemediationPhase], constants.PhaseMonitored)
	}
}

func TestIntegrationDryRunNoChanges(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-b200-1",
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
		DryRun:               true,
		InstanceTypeFilter:   "b200.*",
		Action:               config.ActionConfig{Type: "vm-reset", Timeout: 30 * time.Minute, MaxRetries: 3},
		Guardrails:           config.GuardrailsConfig{GlobalMaxCordoned: 5, PerPoolMaxCordoned: 2},
		DrainTimeout:         10 * time.Minute,
		CrusoeAPISecret:      "test-secret",
		CrusoeProjectID:      "proj-1",
		NodeSelector:         config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	crusoeClient := crusoe.NewClient("http://localhost", "test-access", "test-secret", "proj-1")
	stepFactory := actions.NewFactory(k8sClient, crusoeClient)

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     k8s.NewDrainManager(k8sClient, clientset, cfg.DrainTimeout, true),
		StepFactory:  stepFactory,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -61)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Discoverer:   discovery.NewDiscoverer(k8sClient, cfg),
		Config:       cfg,
		Recorder:     record.NewFakeRecorder(20),
		ReportWriter: nil,
	}

	mgr := NewManager(deps)
	_, err := mgr.Run(context.Background())
	if err != nil {
		t.Fatalf("Run failed: %v", err)
	}

	node, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-b200-1", metav1.GetOptions{})
	if node.Spec.Unschedulable {
		t.Error("node should not be cordoned in dry-run mode")
	}
	if node.Labels[constants.LabelRemediationManaged] != "" {
		t.Error("node should not have managed label in dry-run mode")
	}
}

func TestIntegrationRemediationCooldownSkipsRemediation(t *testing.T) {
	// Node was remediated recently — should be skipped due to remediationCooldown
	recentTime := time.Now().AddDate(0, 0, -3).Format(time.RFC3339) // 3 days ago, within 7-day remediationCooldown

	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-b200-1",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-001",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
				Annotations: map[string]string{
					constants.AnnotationActionCompletedAt: recentTime,
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
		DryRun:               false,
		InstanceTypeFilter:   "b200.*",
		Action:               config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 3},
		Guardrails:           config.GuardrailsConfig{GlobalMaxCordoned: 5, PerPoolMaxCordoned: 2},
		DrainTimeout:         10 * time.Minute,
		CrusoeAPISecret:      "test-secret",
		CrusoeProjectID:      "proj-1",
		NodeSelector:         config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	crusoeClient := crusoe.NewClient("http://localhost", "test-access", "test-secret", "proj-1")
	stepFactory := actions.NewFactory(k8sClient, crusoeClient)

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     k8s.NewDrainManager(k8sClient, clientset, cfg.DrainTimeout, true),
		StepFactory:  stepFactory,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -61)}, // 61 days uptime
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Discoverer:   discovery.NewDiscoverer(k8sClient, cfg),
		Config:       cfg,
		Recorder:     record.NewFakeRecorder(20),
		ReportWriter: nil,
	}

	mgr := NewManager(deps)
	_, err := mgr.Run(context.Background())
	if err != nil {
		t.Fatalf("Run failed: %v", err)
	}

	// Node should NOT be cordoned — it's in remediationCooldown
	node, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-b200-1", metav1.GetOptions{})
	if node.Spec.Unschedulable {
		t.Error("node should not be cordoned during remediationCooldown")
	}
}
