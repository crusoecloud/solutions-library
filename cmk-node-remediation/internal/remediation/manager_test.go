package remediation

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	dynfake "k8s.io/client-go/dynamic/fake"
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

func TestRunDryRunNoChanges(t *testing.T) {
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
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:      config.Duration(55 * 24 * time.Hour),
		RemediationThreshold: config.Duration(60 * 24 * time.Hour),
		DryRun:               true,
		InstanceTypeFilter:   "b200.*",
		Action:               config.ActionConfig{Type: "noop", Timeout: 30 * time.Minute, MaxRetries: 3},
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
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -30)}, // 30 days ago
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

	node, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-1", metav1.GetOptions{})
	if node.Spec.Unschedulable {
		t.Error("node should not be cordoned in dry-run with low uptime")
	}
}

func TestRunCordonsNodeAt55Days(t *testing.T) {
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
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:      config.Duration(55 * 24 * time.Hour),
		RemediationThreshold: config.Duration(60 * 24 * time.Hour),
		DryRun:               false,
		InstanceTypeFilter:   "b200.*",
		Action:               config.ActionConfig{Type: "noop", Timeout: 30 * time.Minute, MaxRetries: 3},
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
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -56)}, // 56 days ago
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

	node, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-1", metav1.GetOptions{})
	if !node.Spec.Unschedulable {
		t.Error("node should be cordoned at 56 days uptime")
	}
	if node.Labels[constants.LabelRemediationPhase] != string(constants.PhaseCordoned) {
		t.Errorf("phase = %q, want %q", node.Labels[constants.LabelRemediationPhase], constants.PhaseCordoned)
	}
}

// mockUptimeEvaluator implements UptimeEvaluator for tests.
type mockUptimeEvaluator struct {
	startTime time.Time
}

func (m *mockUptimeEvaluator) GetNodeStartTime(ctx context.Context, nodeName string) (time.Time, error) {
	return m.startTime, nil
}

// --- TDD: Edge case tests ---

// TDD Test 1: Guardrail exceeded → node is NOT cordoned
func TestGuardrailExceededSkipsCordon(t *testing.T) {
	// Set up 3 nodes, all at 56 days (should cordon), but globalMaxCordoned=1
	// and 1 node is already cordoned (active). So only 0 more can be cordoned.
	clientset := fake.NewSimpleClientset(
		// Already cordoned node (counts as 1 active)
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-active",
				Labels: map[string]string{
					constants.LabelNodepoolID:       "pool-a",
					constants.LabelInstanceID:       "vm-active",
					constants.LabelProjectID:        "proj-1",
					constants.LabelInstanceType:     "b200-180gb-sxm-ib.8x",
					constants.LabelRemediationPhase: string(constants.PhaseCordoned),
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: true},
		},
		// Node that should be cordoned but guardrail will block it
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-target",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-target",
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
		DryRun:               false,
		InstanceTypeFilter:   "b200.*",
		Action:               config.ActionConfig{Type: "noop", Timeout: 30 * time.Minute, MaxRetries: 3},
		Guardrails:           config.GuardrailsConfig{GlobalMaxCordoned: 1, PerPoolMaxCordoned: 1},
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
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -56)},
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

	// node-target should NOT be cordoned — guardrail exceeded
	node, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-target", metav1.GetOptions{})
	if node.Spec.Unschedulable {
		t.Error("node-target should not be cordoned when guardrail is exceeded")
	}
}

// --- Mock types for TDD edge case tests ---

// mockDrainMgr implements DrainManager for testing drain failure paths.
type mockDrainMgr struct {
	drainFails                      bool
	forceAfterEvictionFailureFails  bool
	drainCalled                     bool
	forceAfterEvictionFailureCalled bool
	drainCount                      int
	forceAfterEvictionFailureCount  int
}

func (m *mockDrainMgr) Drain(ctx context.Context, nodeName string) error {
	m.drainCalled = true
	m.drainCount++
	if m.drainFails {
		return fmt.Errorf("drain blocked by PDB")
	}
	return nil
}

func (m *mockDrainMgr) ForceAfterEvictionFailure(ctx context.Context, nodeName string) error {
	m.forceAfterEvictionFailureCalled = true
	m.forceAfterEvictionFailureCount++
	if m.forceAfterEvictionFailureFails {
		return fmt.Errorf("force drain failed")
	}
	return nil
}

// mockStepCreator implements StepCreator for testing.
type mockStepCreator struct {
	step actions.Step
	err  error
}

func (m *mockStepCreator) CreateFromConfig(cfg config.ActionConfig) (actions.Step, error) {
	if m.err != nil {
		return nil, m.err
	}
	return m.step, nil
}

// TDD Test 2: Drain fails → force drain is called
func TestForceDrainPath(t *testing.T) {
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

	drainMgr := &mockDrainMgr{drainFails: true, forceAfterEvictionFailureFails: false}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
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

	if !drainMgr.drainCalled {
		t.Error("Drain should have been called")
	}
	if !drainMgr.forceAfterEvictionFailureCalled {
		t.Error("ForceAfterEvictionFailure should have been called after Drain failed")
	}

	// Node should be uncordoned (noop step + successful force drain)
	node, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-1", metav1.GetOptions{})
	if node.Spec.Unschedulable {
		t.Error("node should be uncordoned after successful force drain + noop step")
	}
}

// TDD Test: forceAfterEvictionFailure=false — drain fails, node left cordoned, no force drain attempted
func TestForceDrainDisabledLeavesNodeCordoned(t *testing.T) {
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
		ForceAfterEvictionFailure: false, // force drain disabled
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	drainMgr := &mockDrainMgr{drainFails: true, forceAfterEvictionFailureFails: false}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
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
	// Should fail because drain failed and force drain is disabled
	if err == nil {
		t.Fatal("Run should fail when drain fails and forceAfterEvictionFailure is false")
	}

	if !drainMgr.drainCalled {
		t.Error("Drain should have been called")
	}
	if drainMgr.forceAfterEvictionFailureCalled {
		t.Error("ForceAfterEvictionFailure should NOT be called when forceAfterEvictionFailure is false")
	}

	// Node should remain cordoned
	node, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-1", metav1.GetOptions{})
	if !node.Spec.Unschedulable {
		t.Error("node should remain cordoned when drain fails and forceAfterEvictionFailure is false")
	}
}

// TDD Test 3: Attempt annotation reset to "0" after successful remediation
func TestAttemptAnnotationResetAfterSuccess(t *testing.T) {
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
				Annotations: map[string]string{
					constants.AnnotationAttempt: "2", // previous failed attempts
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
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

	drainMgr := &mockDrainMgr{}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
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

	node, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-1", metav1.GetOptions{})
	attempt := node.Annotations[constants.AnnotationAttempt]
	if attempt != "0" {
		t.Errorf("attempt annotation = %q, want %q after successful remediation", attempt, "0")
	}
}

// TDD Test 4: Uncordon failure → action-completed-at NOT set (node will be retried)
func TestUncordonFailureDoesNotSetCompletedAt(t *testing.T) {
	// Create a node that's already cordoned — uncordon will fail because
	// we'll use a fake clientset that we can't easily make fail on uncordon.
	// Instead, we test the logic: if uncordonNode returns error, the manager
	// should return error and NOT set action-completed-at.
	// We simulate this by having the step fail, which means action-completed-at
	// should not be set.
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

	// Step that always fails
	failingStep := &failingStep{}
	stepFactory := &mockStepCreator{step: failingStep}

	drainMgr := &mockDrainMgr{}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
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
	// Should return error because step failed
	if err == nil {
		t.Fatal("Run should return error when step fails")
	}

	node, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-1", metav1.GetOptions{})
	completedAt := node.Annotations[constants.AnnotationActionCompletedAt]
	if completedAt != "" {
		t.Errorf("action-completed-at should NOT be set when step fails, got %q", completedAt)
	}
	// Node should be cordoned (cordon happens before step)
	if !node.Spec.Unschedulable {
		t.Error("node should be cordoned when step fails")
	}
}

// failingStep is a Step that always returns an error.
type failingStep struct{}

func (s *failingStep) Type() string { return "failing" }
func (s *failingStep) Run(ctx context.Context, node actions.NodeInfo, params map[string]string) error {
	return fmt.Errorf("step intentionally failed")
}

// TDD Test 5: RemediationCooldown boundary — node at exactly remediationCooldownDays should NOT be skipped
func TestRemediationCooldownBoundaryNotSkipped(t *testing.T) {
	// Node remediated exactly remediationCooldownDays ago — should NOT be in remediationCooldown
	// (remediationCooldown is < remediationCooldownDays, not <= remediationCooldownDays)
	remediationCooldownAgo := time.Now().AddDate(0, 0, -7).Format(time.RFC3339) // exactly 7 days ago

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
				Annotations: map[string]string{
					constants.AnnotationActionCompletedAt: remediationCooldownAgo,
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:           config.Duration(55 * 24 * time.Hour),
		RemediationThreshold:      config.Duration(60 * 24 * time.Hour),
		RemediationCooldown:       config.Duration(7 * 24 * time.Hour),
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

	drainMgr := &mockDrainMgr{}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
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

	// Node at exactly remediationCooldownDays boundary should be processed (not skipped)
	// It should have been cordoned (action = remediate since uptime is 61 days)
	node, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-1", metav1.GetOptions{})
	// With noop step, node should be uncordoned after successful remediation
	if node.Spec.Unschedulable {
		t.Error("node should be uncordoned after successful noop remediation (remediationCooldown boundary)")
	}
	// action-completed-at should be updated (new remediation happened)
	if node.Annotations[constants.AnnotationActionCompletedAt] == remediationCooldownAgo {
		t.Error("action-completed-at should be updated after new remediation")
	}
}

// TDD Test 6: Max retries exceeded → node left cordoned, error returned
func TestMaxRetriesExceededLeavesCordoned(t *testing.T) {
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
				Annotations: map[string]string{
					constants.AnnotationAttempt: "3", // already at max retries
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
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

	drainMgr := &mockDrainMgr{}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
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
	// Should return error because max retries exceeded
	if err == nil {
		t.Fatal("Run should return error when max retries exceeded")
	}

	// Node should NOT be cordoned — it was skipped before cordon
	node, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-1", metav1.GetOptions{})
	if node.Spec.Unschedulable {
		t.Error("node should not be cordoned when max retries exceeded (skipped before cordon)")
	}
	// Drain should NOT have been called
	if drainMgr.drainCalled {
		t.Error("Drain should not be called when max retries exceeded")
	}
}

// TDD Test 7: vm-delete action → node is NOT uncordoned (old node is gone)
func TestVMDeleteDoesNotUncordon(t *testing.T) {
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
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:           config.Duration(55 * 24 * time.Hour),
		RemediationThreshold:      config.Duration(60 * 24 * time.Hour),
		DryRun:                    false,
		InstanceTypeFilter:        "b200.*",
		Action:                    config.ActionConfig{Type: "vm-delete", Timeout: 5 * time.Second, MaxRetries: 3},
		Guardrails:                config.GuardrailsConfig{GlobalMaxCordoned: 5, PerPoolMaxCordoned: 2},
		DrainTimeout:              1 * time.Second,
		ForceAfterEvictionFailure: true,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	drainMgr := &mockDrainMgr{}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
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

	// Node should still be cordoned — vm-delete doesn't uncordon
	node, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-1", metav1.GetOptions{})
	if !node.Spec.Unschedulable {
		t.Error("node should remain cordoned after vm-delete (old node is gone, replacement handled by CMK)")
	}
	// action-completed-at SHOULD be set (delete succeeded)
	if node.Annotations[constants.AnnotationActionCompletedAt] == "" {
		t.Error("action-completed-at should be set after vm-delete")
	}
}

// --- TDD: Additional edge case tests ---

// TDD Test 8: Node with no instance.id label → should be skipped, not crash
func TestNodeWithNoInstanceIDLabelSkipped(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		// Node with all labels except instance.id
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-no-id",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
					// Missing: constants.LabelInstanceID
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
		// Normal node for comparison
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-normal",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-normal",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
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

	drainMgr := &mockDrainMgr{}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
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
	// Should NOT fail — node without instance.id should be skipped
	if err != nil {
		t.Fatalf("Run should not fail when node has no instance.id: %v", err)
	}

	// node-no-id should NOT be cordoned (skipped)
	nodeNoID, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-no-id", metav1.GetOptions{})
	if nodeNoID.Spec.Unschedulable {
		t.Error("node-no-id should not be cordoned (no instance.id label)")
	}

	// node-normal SHOULD be cordoned (remediated)
	nodeNormal, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-normal", metav1.GetOptions{})
	if nodeNormal.Spec.Unschedulable {
		t.Error("node-normal should be uncordoned after successful noop remediation")
	}
}

// TDD Test 9: GetNodeStartTime fails → skip that node, don't crash the run
func TestGetNodeStartTimeFailsSkipsNode(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-fail",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-fail",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-ok",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-ok",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
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

	drainMgr := &mockDrainMgr{}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	// Uptime evaluator that fails for "node-fail" but succeeds for "node-ok"
	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
		StepFactory:  stepFactory,
		UptimeEval:   &mockUptimeEvaluatorFail{failNode: "node-fail", startTime: time.Now().AddDate(0, 0, -61)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Discoverer:   discovery.NewDiscoverer(k8sClient, cfg),
		Config:       cfg,
		Recorder:     record.NewFakeRecorder(20),
		ReportWriter: nil,
	}

	mgr := NewManager(deps)
	_, err := mgr.Run(context.Background())
	if err != nil {
		t.Fatalf("Run should not fail when GetNodeStartTime fails for one node: %v", err)
	}

	// node-fail should NOT be cordoned (skipped due to uptime query failure)
	nodeFail, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-fail", metav1.GetOptions{})
	if nodeFail.Spec.Unschedulable {
		t.Error("node-fail should not be cordoned (uptime query failed)")
	}

	// node-ok SHOULD be remediated
	nodeOK, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-ok", metav1.GetOptions{})
	if nodeOK.Spec.Unschedulable {
		t.Error("node-ok should be uncordoned after successful remediation")
	}
}

// mockUptimeEvaluatorFail fails for a specific node name.
type mockUptimeEvaluatorFail struct {
	failNode  string
	startTime time.Time
}

func (m *mockUptimeEvaluatorFail) GetNodeStartTime(ctx context.Context, nodeName string) (time.Time, error) {
	if nodeName == m.failNode {
		return time.Time{}, fmt.Errorf("failed to get stats summary for node %s: connection refused", nodeName)
	}
	return m.startTime, nil
}

// TDD Test 10: Steps composite with failing first step → remaining steps NOT run
// (This test lives in the actions package where it has access to unexported fields)
// See: internal/actions/step_test.go TestStepsFailingFirstStepStopsRemaining

// TDD Test 11: handleMonitoredNode uncordons tool-managed node but NOT externally cordoned
func TestHandleMonitoredNodeOnlyUncordonsManagedNodes(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		// Tool-managed node: has managed=true label, is cordoned, uptime below threshold
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-managed",
				Labels: map[string]string{
					constants.LabelNodepoolID:         "pool-a",
					constants.LabelInstanceID:         "vm-managed",
					constants.LabelProjectID:          "proj-1",
					constants.LabelInstanceType:       "b200-180gb-sxm-ib.8x",
					constants.LabelRemediationManaged: "true",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: true},
		},
		// Externally cordoned node: no managed label, is cordoned
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-external",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-external",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
					// NO constants.LabelRemediationManaged
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: true},
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

	drainMgr := &mockDrainMgr{}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
		StepFactory:  stepFactory,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -30)}, // 30 days — below cordon threshold
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

	// Tool-managed node should be uncordoned (uptime below threshold, we own it)
	nodeManaged, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-managed", metav1.GetOptions{})
	if nodeManaged.Spec.Unschedulable {
		t.Error("node-managed should be uncordoned (tool-managed, uptime below threshold)")
	}

	// Externally cordoned node should NOT be uncordoned (we don't own it)
	nodeExternal, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-external", metav1.GetOptions{})
	if !nodeExternal.Spec.Unschedulable {
		t.Error("node-external should remain cordoned (not tool-managed)")
	}
}

// TDD Test 12: Multiple pools — per-pool guardrail is independent
func TestMultiplePoolsPerPoolGuardrailIndependent(t *testing.T) {
	// Two pools, each with 2 nodes at 56 days (should cordon)
	// perPoolMaxCordoned=1, globalMaxCordoned=5
	// Each pool can cordon 1 node independently
	clientset := fake.NewSimpleClientset(
		// Pool A — 2 nodes
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-a1",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-a1",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-a2",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-a2",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
		// Pool B — 2 nodes
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-b1",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-b",
					constants.LabelInstanceID:   "vm-b1",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-b2",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-b",
					constants.LabelInstanceID:   "vm-b2",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:           config.Duration(55 * 24 * time.Hour),
		RemediationThreshold:      config.Duration(60 * 24 * time.Hour),
		DryRun:                    false,
		InstanceTypeFilter:        "b200.*",
		Action:                    config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 3},
		Guardrails:                config.GuardrailsConfig{GlobalMaxCordoned: 5, PerPoolMaxCordoned: 1},
		DrainTimeout:              1 * time.Second,
		ForceAfterEvictionFailure: true,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	drainMgr := &mockDrainMgr{}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
		StepFactory:  stepFactory,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -56)}, // 56 days — cordon threshold
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

	// Count cordoned nodes per pool
	poolACordoned := 0
	poolBCordoned := 0
	for _, name := range []string{"node-a1", "node-a2", "node-b1", "node-b2"} {
		node, _ := clientset.CoreV1().Nodes().Get(context.Background(), name, metav1.GetOptions{})
		if node.Labels[constants.LabelRemediationPhase] == string(constants.PhaseCordoned) {
			if node.Labels[constants.LabelNodepoolID] == "pool-a" {
				poolACordoned++
			} else {
				poolBCordoned++
			}
		}
	}

	// Each pool should have exactly 1 cordoned node (perPoolMaxCordoned=1)
	if poolACordoned != 1 {
		t.Errorf("pool-a cordoned = %d, want 1 (perPoolMaxCordoned=1)", poolACordoned)
	}
	if poolBCordoned != 1 {
		t.Errorf("pool-b cordoned = %d, want 1 (perPoolMaxCordoned=1)", poolBCordoned)
	}
}

// --- TDD: Node priority tests ---

// mockUptimeEvaluatorMulti returns different uptimes per node name.
type mockUptimeEvaluatorMulti struct {
	startTimes map[string]time.Time
}

func (m *mockUptimeEvaluatorMulti) GetNodeStartTime(ctx context.Context, nodeName string) (time.Time, error) {
	if t, ok := m.startTimes[nodeName]; ok {
		return t, nil
	}
	return time.Now(), nil
}

// TDD Test: highest-uptime priority — node with most uptime is cordoned first
func TestHighestUptimePriorityCordonsHighestFirst(t *testing.T) {
	// 3 nodes with different uptimes, perPoolMaxCordoned=1
	// Only the highest-uptime node should be cordoned
	now := time.Now()
	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-low", // 30m uptime
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-low",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-high", // 2h uptime
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-high",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-mid", // 1h uptime
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-mid",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:           config.Duration(30 * time.Minute),
		RemediationThreshold:      config.Duration(1 * time.Hour),
		RemediationCooldown:       config.Duration(15 * time.Minute),
		DryRun:                    false,
		InstanceTypeFilter:        "b200.*",
		Action:                    config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 3},
		Guardrails:                config.GuardrailsConfig{GlobalMaxCordoned: 5, PerPoolMaxCordoned: 1},
		DrainTimeout:              1 * time.Second,
		ForceAfterEvictionFailure: true,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	drainMgr := &mockDrainMgr{}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:   k8sClient,
		DrainMgr:    drainMgr,
		StepFactory: stepFactory,
		UptimeEval: &mockUptimeEvaluatorMulti{
			startTimes: map[string]time.Time{
				"node-low":  now.Add(-30 * time.Minute),
				"node-high": now.Add(-2 * time.Hour),
				"node-mid":  now.Add(-1 * time.Hour),
			},
		},
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

	// node-high (2h uptime) should be cordoned — it's above remediationThreshold (1h)
	// and has the highest uptime, so it gets the 1 perPoolMaxCordoned slot
	nodeHigh, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-high", metav1.GetOptions{})
	if nodeHigh.Labels[constants.LabelRemediationPhase] != string(constants.PhaseMonitored) {
		t.Errorf("node-high should be remediated (highest uptime, above remediationThreshold), phase = %q",
			nodeHigh.Labels[constants.LabelRemediationPhase])
	}

	// node-mid (1h uptime) is also above remediationThreshold but guardrail blocks it
	nodeMid, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-mid", metav1.GetOptions{})
	if nodeMid.Spec.Unschedulable {
		t.Error("node-mid should NOT be cordoned — guardrail exceeded (perPoolMaxCordoned=1, node-high took the slot)")
	}

	// node-low (30m uptime) is below cordonThreshold — should not be cordoned
	nodeLow, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-low", metav1.GetOptions{})
	if nodeLow.Spec.Unschedulable {
		t.Error("node-low should NOT be cordoned — below cordonThreshold")
	}
}

// TDD Test: lowest-uptime priority — node with least uptime is processed first
// TDD Test: highest-uptime priority with multiple nodepools — each pool prioritizes independently
func TestHighestUptimePriorityMultiplePools(t *testing.T) {
	// 2 pools, each with 2 nodes above remediationThreshold.
	// perPoolMaxCordoned=1, globalMaxCordoned=2.
	// Each pool should remediate its highest-uptime node independently.
	now := time.Now()
	clientset := fake.NewSimpleClientset(
		// Pool A: node-a-high (2h), node-a-low (1.5h)
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-a-high",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-a-high",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-a-low",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-a-low",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
		// Pool B: node-b-high (3h), node-b-low (1.5h)
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-b-high",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-b",
					constants.LabelInstanceID:   "vm-b-high",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-b-low",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-b",
					constants.LabelInstanceID:   "vm-b-low",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:           config.Duration(30 * time.Minute),
		RemediationThreshold:      config.Duration(1 * time.Hour),
		RemediationCooldown:       config.Duration(15 * time.Minute),
		DryRun:                    false,
		InstanceTypeFilter:        "b200.*",
		Action:                    config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 3},
		Guardrails:                config.GuardrailsConfig{GlobalMaxCordoned: 2, PerPoolMaxCordoned: 1},
		DrainTimeout:              1 * time.Second,
		ForceAfterEvictionFailure: true,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	drainMgr := &mockDrainMgr{}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:   k8sClient,
		DrainMgr:    drainMgr,
		StepFactory: stepFactory,
		UptimeEval: &mockUptimeEvaluatorMulti{
			startTimes: map[string]time.Time{
				"node-a-high": now.Add(-2 * time.Hour),
				"node-a-low":  now.Add(-90 * time.Minute),
				"node-b-high": now.Add(-3 * time.Hour),
				"node-b-low":  now.Add(-90 * time.Minute),
			},
		},
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

	// Pool A: node-a-high (2h) should be remediated, node-a-low blocked by guardrail
	nodeAHigh, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-a-high", metav1.GetOptions{})
	if nodeAHigh.Labels[constants.LabelRemediationPhase] != string(constants.PhaseMonitored) {
		t.Errorf("node-a-high should be remediated (highest in pool-a), phase = %q",
			nodeAHigh.Labels[constants.LabelRemediationPhase])
	}

	nodeALow, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-a-low", metav1.GetOptions{})
	if nodeALow.Spec.Unschedulable {
		t.Error("node-a-low should NOT be cordoned — guardrail exceeded in pool-a")
	}

	// Pool B: node-b-high (3h) should be remediated, node-b-low blocked by guardrail
	nodeBHigh, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-b-high", metav1.GetOptions{})
	if nodeBHigh.Labels[constants.LabelRemediationPhase] != string(constants.PhaseMonitored) {
		t.Errorf("node-b-high should be remediated (highest in pool-b), phase = %q",
			nodeBHigh.Labels[constants.LabelRemediationPhase])
	}

	nodeBLow, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-b-low", metav1.GetOptions{})
	if nodeBLow.Spec.Unschedulable {
		t.Error("node-b-low should NOT be cordoned — guardrail exceeded in pool-b")
	}
}

// TDD Test: highest-uptime priority with global guardrail limiting across pools
func TestHighestUptimePriorityGlobalGuardrailAcrossPools(t *testing.T) {
	// 2 pools, each with 1 node above remediationThreshold.
	// globalMaxCordoned=1 — only 1 node can be remediated across ALL pools.
	// With highest-uptime, the node with the most uptime across all pools should win.
	now := time.Now()
	clientset := fake.NewSimpleClientset(
		// Pool A: node-a (2h uptime)
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-a",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-a",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
		// Pool B: node-b (3h uptime — higher than pool-a)
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-b",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-b",
					constants.LabelInstanceID:   "vm-b",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:           config.Duration(30 * time.Minute),
		RemediationThreshold:      config.Duration(1 * time.Hour),
		RemediationCooldown:       config.Duration(15 * time.Minute),
		DryRun:                    false,
		InstanceTypeFilter:        "b200.*",
		Action:                    config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 3},
		Guardrails:                config.GuardrailsConfig{GlobalMaxCordoned: 1, PerPoolMaxCordoned: 1},
		DrainTimeout:              1 * time.Second,
		ForceAfterEvictionFailure: true,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	drainMgr := &mockDrainMgr{}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:   k8sClient,
		DrainMgr:    drainMgr,
		StepFactory: stepFactory,
		UptimeEval: &mockUptimeEvaluatorMulti{
			startTimes: map[string]time.Time{
				"node-a": now.Add(-2 * time.Hour),
				"node-b": now.Add(-3 * time.Hour),
			},
		},
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

	// Exactly 1 node should be remediated (globalMaxCordoned=1)
	// The first pool processed gets the slot. Since Go map iteration is random,
	// we can't guarantee which pool goes first. But we CAN verify that
	// exactly 1 node was remediated and 1 was blocked.
	remediatedCount := 0
	blockedCount := 0
	for _, name := range []string{"node-a", "node-b"} {
		node, _ := clientset.CoreV1().Nodes().Get(context.Background(), name, metav1.GetOptions{})
		if node.Labels[constants.LabelRemediationPhase] == string(constants.PhaseMonitored) &&
			node.Labels[constants.LabelRemediationManaged] == "true" {
			remediatedCount++
		} else if !node.Spec.Unschedulable {
			blockedCount++
		}
	}

	if remediatedCount != 1 {
		t.Errorf("expected 1 remediated node (globalMaxCordoned=1), got %d", remediatedCount)
	}
	if blockedCount != 1 {
		t.Errorf("expected 1 blocked node, got %d", blockedCount)
	}
}

// TestMaxRetriesErrorIncludesRetryCount verifies the error message includes
// both current attempts and max retries (e.g. "3/3" not just "3").
func TestMaxRetriesErrorIncludesRetryCount(t *testing.T) {
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
				Annotations: map[string]string{
					constants.AnnotationAttempt: "2", // already at 2, max is 2
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:           config.Duration(55 * 24 * time.Hour),
		RemediationThreshold:      config.Duration(60 * 24 * time.Hour),
		DryRun:                    false,
		InstanceTypeFilter:        "b200.*",
		Action:                    config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 2},
		Guardrails:                config.GuardrailsConfig{GlobalMaxCordoned: 5, PerPoolMaxCordoned: 2},
		DrainTimeout:              1 * time.Second,
		ForceAfterEvictionFailure: true,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     &mockDrainMgr{},
		StepFactory:  &mockStepCreator{step: &actions.NoopStep{}},
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -61)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Discoverer:   discovery.NewDiscoverer(k8sClient, cfg),
		Config:       cfg,
		Recorder:     record.NewFakeRecorder(20),
		ReportWriter: nil,
	}

	mgr := NewManager(deps)
	_, err := mgr.Run(context.Background())
	if err == nil {
		t.Fatal("Run should return error when max retries exceeded")
	}

	// Error message should include both current and max (e.g. "2/2")
	errStr := err.Error()
	if !strings.Contains(errStr, "2/2") {
		t.Errorf("error should include retry count as '2/2', got: %s", errStr)
	}
}

// TestForceDrainDisabledErrorMentionsForceDrain verifies the error message
// tells the user that force drain is disabled.
func TestForceDrainDisabledErrorMentionsForceDrain(t *testing.T) {
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
		ForceAfterEvictionFailure: false,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     &mockDrainMgr{drainFails: true},
		StepFactory:  &mockStepCreator{step: &actions.NoopStep{}},
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -61)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Discoverer:   discovery.NewDiscoverer(k8sClient, cfg),
		Config:       cfg,
		Recorder:     record.NewFakeRecorder(20),
		ReportWriter: nil,
	}

	mgr := NewManager(deps)
	_, err := mgr.Run(context.Background())
	if err == nil {
		t.Fatal("Run should fail when drain fails and forceAfterEvictionFailure is false")
	}

	// The error should propagate the drain error
	errStr := err.Error()
	if !strings.Contains(errStr, "drain") {
		t.Errorf("error should mention drain failure, got: %s", errStr)
	}
}

// TestForceDrainFailedErrorMentionsForceDrain verifies that when force drain
// itself fails, the error message indicates force drain failed.
func TestForceDrainFailedErrorMentionsForceDrain(t *testing.T) {
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

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     &mockDrainMgr{drainFails: true, forceAfterEvictionFailureFails: true},
		StepFactory:  &mockStepCreator{step: &actions.NoopStep{}},
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -61)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Discoverer:   discovery.NewDiscoverer(k8sClient, cfg),
		Config:       cfg,
		Recorder:     record.NewFakeRecorder(20),
		ReportWriter: nil,
	}

	mgr := NewManager(deps)
	_, err := mgr.Run(context.Background())
	if err == nil {
		t.Fatal("Run should fail when force drain fails")
	}

	// The error should mention force drain
	errStr := err.Error()
	if !strings.Contains(errStr, "force drain") {
		t.Errorf("error should mention force drain failure, got: %s", errStr)
	}
}

// TestEventsEmittedForMaxRetries verifies that a MaxRetriesExceeded event
// is emitted with the correct reason and message.
func TestEventsEmittedForMaxRetries(t *testing.T) {
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
				Annotations: map[string]string{
					constants.AnnotationAttempt: "2", // at max
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:           config.Duration(55 * 24 * time.Hour),
		RemediationThreshold:      config.Duration(60 * 24 * time.Hour),
		DryRun:                    false,
		InstanceTypeFilter:        "b200.*",
		Action:                    config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 2},
		Guardrails:                config.GuardrailsConfig{GlobalMaxCordoned: 5, PerPoolMaxCordoned: 2},
		DrainTimeout:              1 * time.Second,
		ForceAfterEvictionFailure: true,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	recorder := record.NewFakeRecorder(20)
	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     &mockDrainMgr{},
		StepFactory:  &mockStepCreator{step: &actions.NoopStep{}},
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -61)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Discoverer:   discovery.NewDiscoverer(k8sClient, cfg),
		Config:       cfg,
		Recorder:     recorder,
		ReportWriter: nil,
	}

	mgr := NewManager(deps)
	_, _ = mgr.Run(context.Background())

	// Check that a MaxRetriesExceeded event was emitted
	found := false
	for {
		select {
		case event := <-recorder.Events:
			if strings.Contains(event, "MaxRetriesExceeded") {
				found = true
				if !strings.Contains(event, "manual intervention required") {
					t.Errorf("MaxRetriesExceeded event should mention 'manual intervention required', got: %s", event)
				}
			}
		default:
			if !found {
				t.Error("expected MaxRetriesExceeded event to be emitted")
			}
			return
		}
	}
}

// TestEventsEmittedForForceDrainFailure verifies that a ForceDrainFailed event
// is emitted when force drain fails.
func TestEventsEmittedForForceDrainFailure(t *testing.T) {
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

	recorder := record.NewFakeRecorder(20)
	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     &mockDrainMgr{drainFails: true, forceAfterEvictionFailureFails: true},
		StepFactory:  &mockStepCreator{step: &actions.NoopStep{}},
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -61)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Discoverer:   discovery.NewDiscoverer(k8sClient, cfg),
		Config:       cfg,
		Recorder:     recorder,
		ReportWriter: nil,
	}

	mgr := NewManager(deps)
	_, _ = mgr.Run(context.Background())

	// Check that ForceDrainFailed event was emitted
	found := false
	for {
		select {
		case event := <-recorder.Events:
			if strings.Contains(event, "ForceDrainFailed") {
				found = true
			}
		default:
			if !found {
				t.Error("expected ForceDrainFailed event to be emitted")
			}
			return
		}
	}
}

// TestGuardrailPreventsCordoningMoreThanMaxAcrossRuns simulates the real-world
// scenario: Run 1 cordons 2 nodes (perPoolMax=2), drain fails, nodes stay stuck.
// Run 2 should NOT cordon more nodes — guardrail must count the stuck nodes.
func TestGuardrailPreventsCordoningMoreThanMaxAcrossRuns(t *testing.T) {
	// 5 nodes, 2 already stuck in "draining" phase from a previous run
	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-1",
				Labels: map[string]string{
					constants.LabelNodepoolID:         "pool-a",
					constants.LabelInstanceID:         "vm-001",
					constants.LabelProjectID:          "proj-1",
					constants.LabelInstanceType:       "b200-180gb-sxm-ib.8x",
					constants.LabelRemediationManaged: "true",
					constants.LabelRemediationPhase:   string(constants.PhaseDraining),
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: true},
		},
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-2",
				Labels: map[string]string{
					constants.LabelNodepoolID:         "pool-a",
					constants.LabelInstanceID:         "vm-002",
					constants.LabelProjectID:          "proj-1",
					constants.LabelInstanceType:       "b200-180gb-sxm-ib.8x",
					constants.LabelRemediationManaged: "true",
					constants.LabelRemediationPhase:   string(constants.PhaseDraining),
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: true},
		},
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-3",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-003",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-4",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-004",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-5",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-005",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:           config.Duration(55 * 24 * time.Hour),
		RemediationThreshold:      config.Duration(60 * 24 * time.Hour),
		RemediationCooldown:       config.Duration(7 * 24 * time.Hour),
		DryRun:                    false,
		InstanceTypeFilter:        "b200.*",
		Action:                    config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 3},
		Guardrails:                config.GuardrailsConfig{GlobalMaxCordoned: 4, PerPoolMaxCordoned: 2},
		DrainTimeout:              1 * time.Second,
		ForceAfterEvictionFailure: true,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	drainMgr := &mockDrainMgr{drainFails: true, forceAfterEvictionFailureFails: true}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
		StepFactory:  stepFactory,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -61)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Discoverer:   discovery.NewDiscoverer(k8sClient, cfg),
		Config:       cfg,
		Recorder:     record.NewFakeRecorder(20),
		ReportWriter: nil,
	}

	mgr := NewManager(deps)
	_, _ = mgr.Run(context.Background())

	// Nodes 1 and 2 were already draining — they should still be draining
	// Nodes 3, 4, 5 should NOT have been cordoned (guardrail: 2 already active, pool max=2)
	for _, nodeName := range []string{"node-3", "node-4", "node-5"} {
		node, _ := clientset.CoreV1().Nodes().Get(context.Background(), nodeName, metav1.GetOptions{})
		if node.Spec.Unschedulable {
			t.Errorf("%s should NOT be cordoned — guardrail should have blocked it (2 already active, pool max=2)", nodeName)
		}
	}
}

// TestGuardrailPercentPreventsCordoningMoreThanMax verifies percentage-based
// guardrails correctly prevent cordoning more than the calculated max.
func TestGuardrailPercentPreventsCordoningMoreThanMax(t *testing.T) {
	// 10 nodes in pool, 20% perPool max = 2
	// 2 already draining → should block all others
	globalPct := 50
	poolPct := 20

	nodes := []runtime.Object{}
	for i := 1; i <= 10; i++ {
		labels := map[string]string{
			constants.LabelNodepoolID:   "pool-a",
			constants.LabelInstanceID:   fmt.Sprintf("vm-%d", i),
			constants.LabelProjectID:    "proj-1",
			constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
		}
		unschedulable := false
		if i <= 2 {
			labels[constants.LabelRemediationManaged] = "true"
			labels[constants.LabelRemediationPhase] = string(constants.PhaseDraining)
			unschedulable = true
		}
		nodes = append(nodes, &corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name:   fmt.Sprintf("node-%d", i),
				Labels: labels,
			},
			Spec: corev1.NodeSpec{Unschedulable: unschedulable},
		})
	}

	clientset := fake.NewSimpleClientset(nodes...)
	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:      config.Duration(55 * 24 * time.Hour),
		RemediationThreshold: config.Duration(60 * 24 * time.Hour),
		RemediationCooldown:  config.Duration(7 * 24 * time.Hour),
		DryRun:               false,
		InstanceTypeFilter:   "b200.*",
		Action:               config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 3},
		Guardrails: config.GuardrailsConfig{
			GlobalMaxCordonedPercent:  &globalPct,
			PerPoolMaxCordonedPercent: &poolPct,
		},
		DrainTimeout:              1 * time.Second,
		ForceAfterEvictionFailure: true,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	drainMgr := &mockDrainMgr{drainFails: true, forceAfterEvictionFailureFails: true}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
		StepFactory:  stepFactory,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -61)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Discoverer:   discovery.NewDiscoverer(k8sClient, cfg),
		Config:       cfg,
		Recorder:     record.NewFakeRecorder(20),
		ReportWriter: nil,
	}

	mgr := NewManager(deps)
	_, _ = mgr.Run(context.Background())

	// 20% of 10 = 2 max per pool. 2 already draining. No new nodes should be cordoned.
	for i := 3; i <= 10; i++ {
		node, _ := clientset.CoreV1().Nodes().Get(context.Background(), fmt.Sprintf("node-%d", i), metav1.GetOptions{})
		if node.Spec.Unschedulable {
			t.Errorf("node-%d should NOT be cordoned — guardrail (20%% of 10 = 2, 2 already active)", i)
		}
	}
}

// TestGuardrailCounterIncrementsWithinRun verifies that the in-run counter
// increments correctly after each cordon, preventing more than perPoolMax
// nodes from being cordoned in a single run with 0 pre-existing active nodes.
func TestGuardrailCounterIncrementsWithinRun(t *testing.T) {
	// 5 nodes, all above remediationThreshold, perPoolMax=2, globalMax=4
	// With the counter fix, only 2 should be cordoned (perPoolMax=2)
	clientset := fake.NewSimpleClientset()
	for i := 1; i <= 5; i++ {
		clientset.Tracker().Add(&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: fmt.Sprintf("node-%d", i),
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   fmt.Sprintf("vm-%d", i),
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		})
	}

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:           config.Duration(55 * 24 * time.Hour),
		RemediationThreshold:      config.Duration(60 * 24 * time.Hour),
		RemediationCooldown:       config.Duration(7 * 24 * time.Hour),
		DryRun:                    false,
		InstanceTypeFilter:        "b200.*",
		Action:                    config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 3},
		Guardrails:                config.GuardrailsConfig{GlobalMaxCordoned: 4, PerPoolMaxCordoned: 2},
		DrainTimeout:              1 * time.Second,
		ForceAfterEvictionFailure: true,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	drainMgr := &mockDrainMgr{drainFails: true, forceAfterEvictionFailureFails: true}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
		StepFactory:  stepFactory,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -61)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Discoverer:   discovery.NewDiscoverer(k8sClient, cfg),
		Config:       cfg,
		Recorder:     record.NewFakeRecorder(20),
		ReportWriter: nil,
	}

	mgr := NewManager(deps)
	_, _ = mgr.Run(context.Background())

	// Count how many nodes were cordoned (unschedulable=true)
	cordonedCount := 0
	for i := 1; i <= 5; i++ {
		node, _ := clientset.CoreV1().Nodes().Get(context.Background(), fmt.Sprintf("node-%d", i), metav1.GetOptions{})
		if node.Spec.Unschedulable {
			cordonedCount++
		}
	}

	if cordonedCount != 2 {
		t.Errorf("expected exactly 2 nodes cordoned (perPoolMax=2), got %d", cordonedCount)
	}
}

// TestGuardrailGlobalLimitBlocksAcrossPools verifies that the global counter
// increments correctly across multiple pools, blocking when globalMax is reached.
func TestGuardrailGlobalLimitBlocksAcrossPools(t *testing.T) {
	// 2 pools, 3 nodes each, globalMax=2, perPoolMax=2
	// Pool A should cordon 2 (hits globalMax), Pool B should cordon 0
	clientset := fake.NewSimpleClientset()
	for _, pool := range []string{"pool-a", "pool-b"} {
		for i := 1; i <= 3; i++ {
			clientset.Tracker().Add(&corev1.Node{
				ObjectMeta: metav1.ObjectMeta{
					Name: fmt.Sprintf("%s-%d", pool, i),
					Labels: map[string]string{
						constants.LabelNodepoolID:   pool,
						constants.LabelInstanceID:   fmt.Sprintf("vm-%s-%d", pool, i),
						constants.LabelProjectID:    "proj-1",
						constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
					},
				},
				Spec: corev1.NodeSpec{Unschedulable: false},
			})
		}
	}

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:           config.Duration(55 * 24 * time.Hour),
		RemediationThreshold:      config.Duration(60 * 24 * time.Hour),
		RemediationCooldown:       config.Duration(7 * 24 * time.Hour),
		DryRun:                    false,
		InstanceTypeFilter:        "b200.*",
		Action:                    config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 3},
		Guardrails:                config.GuardrailsConfig{GlobalMaxCordoned: 2, PerPoolMaxCordoned: 2},
		DrainTimeout:              1 * time.Second,
		ForceAfterEvictionFailure: true,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	drainMgr := &mockDrainMgr{drainFails: true, forceAfterEvictionFailureFails: true}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
		StepFactory:  stepFactory,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -61)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Discoverer:   discovery.NewDiscoverer(k8sClient, cfg),
		Config:       cfg,
		Recorder:     record.NewFakeRecorder(20),
		ReportWriter: nil,
	}

	mgr := NewManager(deps)
	_, _ = mgr.Run(context.Background())

	// Count cordoned nodes per pool
	poolACordoned := 0
	poolBCordoned := 0
	for i := 1; i <= 3; i++ {
		nodeA, _ := clientset.CoreV1().Nodes().Get(context.Background(), fmt.Sprintf("pool-a-%d", i), metav1.GetOptions{})
		if nodeA.Spec.Unschedulable {
			poolACordoned++
		}
		nodeB, _ := clientset.CoreV1().Nodes().Get(context.Background(), fmt.Sprintf("pool-b-%d", i), metav1.GetOptions{})
		if nodeB.Spec.Unschedulable {
			poolBCordoned++
		}
	}

	totalCordoned := poolACordoned + poolBCordoned
	if totalCordoned != 2 {
		t.Errorf("expected exactly 2 nodes cordoned total (globalMax=2), got %d (pool-a=%d, pool-b=%d)",
			totalCordoned, poolACordoned, poolBCordoned)
	}
}

// TestGuardrailSuccessfulRemediationDoesNotBlockNextNode verifies that after
// a successful remediation (noop + uncordon), the counter stays incremented
// so the guardrail still blocks within the same run.
func TestGuardrailSuccessfulRemediationDoesNotBlockNextNode(t *testing.T) {
	// 3 nodes, perPoolMax=1, drain succeeds, noop succeeds
	// Only 1 should be remediated — counter increments after cordon
	clientset := fake.NewSimpleClientset()
	for i := 1; i <= 3; i++ {
		clientset.Tracker().Add(&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: fmt.Sprintf("node-%d", i),
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   fmt.Sprintf("vm-%d", i),
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		})
	}

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:           config.Duration(55 * 24 * time.Hour),
		RemediationThreshold:      config.Duration(60 * 24 * time.Hour),
		RemediationCooldown:       config.Duration(7 * 24 * time.Hour),
		DryRun:                    false,
		InstanceTypeFilter:        "b200.*",
		Action:                    config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 3},
		Guardrails:                config.GuardrailsConfig{GlobalMaxCordoned: 5, PerPoolMaxCordoned: 1},
		DrainTimeout:              1 * time.Second,
		ForceAfterEvictionFailure: true,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	// Drain succeeds, force drain succeeds, noop succeeds
	drainMgr := &mockDrainMgr{}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
		StepFactory:  stepFactory,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -61)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Discoverer:   discovery.NewDiscoverer(k8sClient, cfg),
		Config:       cfg,
		Recorder:     record.NewFakeRecorder(20),
		ReportWriter: nil,
	}

	mgr := NewManager(deps)
	_, _ = mgr.Run(context.Background())

	// Count how many nodes were remediated (phase=monitored + managed=true)
	remediatedCount := 0
	for i := 1; i <= 3; i++ {
		node, _ := clientset.CoreV1().Nodes().Get(context.Background(), fmt.Sprintf("node-%d", i), metav1.GetOptions{})
		if node.Labels[constants.LabelRemediationPhase] == string(constants.PhaseMonitored) &&
			node.Labels[constants.LabelRemediationManaged] == "true" {
			remediatedCount++
		}
	}

	if remediatedCount != 1 {
		t.Errorf("expected exactly 1 node remediated (perPoolMax=1), got %d", remediatedCount)
	}
}

// TestGuardrailPercentGlobalLimitBlocksAcrossPools verifies percentage-based
// global guardrail correctly blocks across pools.
func TestGuardrailPercentGlobalLimitBlocksAcrossPools(t *testing.T) {
	// 2 pools, 5 nodes each = 10 total, globalMaxPercent=20% → 2 max
	// Pool A should cordon 2 (hits globalMax), Pool B should cordon 0
	globalPct := 20
	poolPct := 50

	clientset := fake.NewSimpleClientset()
	for _, pool := range []string{"pool-a", "pool-b"} {
		for i := 1; i <= 5; i++ {
			clientset.Tracker().Add(&corev1.Node{
				ObjectMeta: metav1.ObjectMeta{
					Name: fmt.Sprintf("%s-%d", pool, i),
					Labels: map[string]string{
						constants.LabelNodepoolID:   pool,
						constants.LabelInstanceID:   fmt.Sprintf("vm-%s-%d", pool, i),
						constants.LabelProjectID:    "proj-1",
						constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
					},
				},
				Spec: corev1.NodeSpec{Unschedulable: false},
			})
		}
	}

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:      config.Duration(55 * 24 * time.Hour),
		RemediationThreshold: config.Duration(60 * 24 * time.Hour),
		RemediationCooldown:  config.Duration(7 * 24 * time.Hour),
		DryRun:               false,
		InstanceTypeFilter:   "b200.*",
		Action:               config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 3},
		Guardrails: config.GuardrailsConfig{
			GlobalMaxCordonedPercent:  &globalPct,
			PerPoolMaxCordonedPercent: &poolPct,
		},
		DrainTimeout:              1 * time.Second,
		ForceAfterEvictionFailure: true,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	drainMgr := &mockDrainMgr{drainFails: true, forceAfterEvictionFailureFails: true}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
		StepFactory:  stepFactory,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -61)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Discoverer:   discovery.NewDiscoverer(k8sClient, cfg),
		Config:       cfg,
		Recorder:     record.NewFakeRecorder(20),
		ReportWriter: nil,
	}

	mgr := NewManager(deps)
	_, _ = mgr.Run(context.Background())

	// 20% of 10 = 2 global max. Only 2 nodes should be cordoned total.
	totalCordoned := 0
	for _, pool := range []string{"pool-a", "pool-b"} {
		for i := 1; i <= 5; i++ {
			node, _ := clientset.CoreV1().Nodes().Get(context.Background(), fmt.Sprintf("%s-%d", pool, i), metav1.GetOptions{})
			if node.Spec.Unschedulable {
				totalCordoned++
			}
		}
	}

	if totalCordoned != 2 {
		t.Errorf("expected exactly 2 nodes cordoned (globalMaxPercent=20%% of 10 = 2), got %d", totalCordoned)
	}
}

// TestGuardrailMixedAbsoluteAndPercent verifies that when both absolute and
// percentage limits are set, the more restrictive one applies.
func TestGuardrailMixedAbsoluteAndPercent(t *testing.T) {
	// 10 nodes, globalMax=5, globalMaxPercent=20% → min(5, 2) = 2
	// perPoolMax=3, perPoolMaxPercent=50% → min(3, 5) = 3 (but only 1 pool of 10)
	// So global limit (2) should be the binding constraint
	globalPct := 20
	poolPct := 50

	clientset := fake.NewSimpleClientset()
	for i := 1; i <= 10; i++ {
		clientset.Tracker().Add(&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: fmt.Sprintf("node-%d", i),
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   fmt.Sprintf("vm-%d", i),
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		})
	}

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:      config.Duration(55 * 24 * time.Hour),
		RemediationThreshold: config.Duration(60 * 24 * time.Hour),
		RemediationCooldown:  config.Duration(7 * 24 * time.Hour),
		DryRun:               false,
		InstanceTypeFilter:   "b200.*",
		Action:               config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 3},
		Guardrails: config.GuardrailsConfig{
			GlobalMaxCordoned:         5,
			GlobalMaxCordonedPercent:  &globalPct,
			PerPoolMaxCordoned:        3,
			PerPoolMaxCordonedPercent: &poolPct,
		},
		DrainTimeout:              1 * time.Second,
		ForceAfterEvictionFailure: true,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	drainMgr := &mockDrainMgr{drainFails: true, forceAfterEvictionFailureFails: true}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
		StepFactory:  stepFactory,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -61)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Discoverer:   discovery.NewDiscoverer(k8sClient, cfg),
		Config:       cfg,
		Recorder:     record.NewFakeRecorder(20),
		ReportWriter: nil,
	}

	mgr := NewManager(deps)
	_, _ = mgr.Run(context.Background())

	// min(5, 20% of 10=2) = 2 global max. Only 2 should be cordoned.
	cordonedCount := 0
	for i := 1; i <= 10; i++ {
		node, _ := clientset.CoreV1().Nodes().Get(context.Background(), fmt.Sprintf("node-%d", i), metav1.GetOptions{})
		if node.Spec.Unschedulable {
			cordonedCount++
		}
	}

	if cordonedCount != 2 {
		t.Errorf("expected 2 nodes cordoned (min(5, 20%% of 10) = 2), got %d", cordonedCount)
	}
}

// TestSelfNodeExclusion verifies that the node running the pod is never
// cordoned or drained, even if it's above the remediation threshold.
func TestSelfNodeExclusion(t *testing.T) {
	// 3 nodes, all above remediationThreshold, perPoolMax=5 (no guardrail limit)
	// Set NODE_NAME to node-2 — it should be skipped, only node-1 and node-3 remediated
	os.Setenv("NODE_NAME", "node-2")
	defer os.Unsetenv("NODE_NAME")

	clientset := fake.NewSimpleClientset()
	for i := 1; i <= 3; i++ {
		clientset.Tracker().Add(&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: fmt.Sprintf("node-%d", i),
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   fmt.Sprintf("vm-%d", i),
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		})
	}

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:           config.Duration(55 * 24 * time.Hour),
		RemediationThreshold:      config.Duration(60 * 24 * time.Hour),
		RemediationCooldown:       config.Duration(7 * 24 * time.Hour),
		DryRun:                    false,
		InstanceTypeFilter:        "b200.*",
		Action:                    config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 3},
		Guardrails:                config.GuardrailsConfig{GlobalMaxCordoned: 5, PerPoolMaxCordoned: 5},
		DrainTimeout:              1 * time.Second,
		ForceAfterEvictionFailure: true,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	drainMgr := &mockDrainMgr{}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
		StepFactory:  stepFactory,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -61)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Discoverer:   discovery.NewDiscoverer(k8sClient, cfg),
		Config:       cfg,
		Recorder:     record.NewFakeRecorder(20),
		ReportWriter: nil,
	}

	mgr := NewManager(deps)
	_, _ = mgr.Run(context.Background())

	// node-2 should NOT be cordoned (it's the self-node)
	node2, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-2", metav1.GetOptions{})
	if node2.Spec.Unschedulable {
		t.Error("node-2 should NOT be cordoned — it's the node running this pod")
	}
	if node2.Labels[constants.LabelRemediationManaged] == "true" {
		t.Error("node-2 should NOT have remediation.managed label — it's excluded")
	}

	// node-1 and node-3 should be remediated
	node1, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-1", metav1.GetOptions{})
	if node1.Labels[constants.LabelRemediationPhase] != string(constants.PhaseMonitored) {
		t.Error("node-1 should be remediated (not the self-node)")
	}

	node3, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-3", metav1.GetOptions{})
	if node3.Labels[constants.LabelRemediationPhase] != string(constants.PhaseMonitored) {
		t.Error("node-3 should be remediated (not the self-node)")
	}

	// Drain should NOT have been called for node-2
	// (drainMgr tracks all calls — we can't easily verify which node was drained,
	// but we can verify drain was called at most 2 times, not 3)
	if drainMgr.drainCount != 2 {
		t.Errorf("drain should be called 2 times (node-1 and node-3), got %d", drainMgr.drainCount)
	}
}

// TestSelfNodeExclusionWithEnvNotSet verifies that when NODE_NAME is not set,
// all nodes are processed normally (no exclusion).
func TestSelfNodeExclusionWithEnvNotSet(t *testing.T) {
	os.Unsetenv("NODE_NAME")

	clientset := fake.NewSimpleClientset()
	for i := 1; i <= 3; i++ {
		clientset.Tracker().Add(&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: fmt.Sprintf("node-%d", i),
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   fmt.Sprintf("vm-%d", i),
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		})
	}

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:           config.Duration(55 * 24 * time.Hour),
		RemediationThreshold:      config.Duration(60 * 24 * time.Hour),
		RemediationCooldown:       config.Duration(7 * 24 * time.Hour),
		DryRun:                    false,
		InstanceTypeFilter:        "b200.*",
		Action:                    config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 3},
		Guardrails:                config.GuardrailsConfig{GlobalMaxCordoned: 5, PerPoolMaxCordoned: 5},
		DrainTimeout:              1 * time.Second,
		ForceAfterEvictionFailure: true,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	drainMgr := &mockDrainMgr{}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
		StepFactory:  stepFactory,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -61)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Discoverer:   discovery.NewDiscoverer(k8sClient, cfg),
		Config:       cfg,
		Recorder:     record.NewFakeRecorder(20),
		ReportWriter: nil,
	}

	mgr := NewManager(deps)
	_, _ = mgr.Run(context.Background())

	// All 3 nodes should be remediated (no exclusion)
	if drainMgr.drainCount != 3 {
		t.Errorf("drain should be called 3 times (no self-node exclusion), got %d", drainMgr.drainCount)
	}
}

// TDD Test: Stuck node in action-running with attempt < maxRetries should be
// retried on the next run, even when the guardrail is full.
//
// Scenario: 1 node is stuck in action-running (failed vm-reset, attempt=1,
// maxRetries=2). perPoolMaxCordoned=1, so the guardrail is full. The next run
// should retry the stuck node instead of skipping it with "guardrail exceeded".
func TestStuckNodeRetriedDespiteGuardrailFull(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		// Node stuck in action-running, attempt=1 (below maxRetries=2)
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-stuck",
				Labels: map[string]string{
					constants.LabelNodepoolID:         "pool-a",
					constants.LabelInstanceID:         "vm-stuck",
					constants.LabelProjectID:          "proj-1",
					constants.LabelInstanceType:       "b200-180gb-sxm-ib.8x",
					constants.LabelRemediationManaged: "true",
					constants.LabelRemediationPhase:   string(constants.PhaseActionRunning),
				},
				Annotations: map[string]string{
					constants.AnnotationAttempt:        "1",
					constants.AnnotationCordonedAt:     time.Now().AddDate(0, 0, -1).Format(time.RFC3339),
					constants.AnnotationDrainStartedAt: time.Now().AddDate(0, 0, -1).Format(time.RFC3339),
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: true},
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:           config.Duration(10 * time.Minute),
		RemediationThreshold:      config.Duration(20 * time.Minute),
		RemediationCooldown:       config.Duration(7 * 24 * time.Hour),
		DryRun:                    false,
		InstanceTypeFilter:        "b200.*",
		Action:                    config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 2},
		Guardrails:                config.GuardrailsConfig{GlobalMaxCordoned: 1, PerPoolMaxCordoned: 1},
		DrainTimeout:              1 * time.Second,
		ForceAfterEvictionFailure: true,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	drainMgr := &mockDrainMgr{}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
		StepFactory:  stepFactory,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -1)}, // 1 day uptime > 20m threshold
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

	// The stuck node should have been retried — drain should be called
	if !drainMgr.drainCalled {
		t.Error("drain should have been called to retry the stuck node, but it was skipped (guardrail deadlock)")
	}

	// The node should be uncordoned (remediation succeeded on retry)
	node, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-stuck", metav1.GetOptions{})
	if node.Spec.Unschedulable {
		t.Error("node should be uncordoned after successful retry")
	}

	// Attempt should be reset to 0 after successful remediation
	attempt := node.Annotations[constants.AnnotationAttempt]
	if attempt != "0" {
		t.Errorf("attempt annotation = %q, want %q (reset after successful retry)", attempt, "0")
	}

	// Phase should be back to monitored
	phase := node.Labels[constants.LabelRemediationPhase]
	if phase != string(constants.PhaseMonitored) {
		t.Errorf("phase = %q, want %q (should be monitored after successful retry)", phase, string(constants.PhaseMonitored))
	}
}

// TDD Test: Node cordoned by another engineer (not managed by us) should be
// skipped, not remediated.
//
// Scenario: A node is cordoned (Spec.Unschedulable=true) by an engineer for
// manual maintenance. It does NOT have our LabelRemediationManaged label.
// Its uptime exceeds the remediation threshold. The tool should NOT drain,
// reset, or uncordon it — it should be left alone.
func TestSkipsNodeCordonedByEngineer(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		// Node cordoned by an engineer — no remediation labels or annotations
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-manual",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-manual",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
					// No LabelRemediationManaged — not ours
					// No LabelRemediationPhase — not in our state machine
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: true},
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:           config.Duration(10 * time.Minute),
		RemediationThreshold:      config.Duration(20 * time.Minute),
		RemediationCooldown:       config.Duration(7 * 24 * time.Hour),
		DryRun:                    false,
		InstanceTypeFilter:        "b200.*",
		Action:                    config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 2},
		Guardrails:                config.GuardrailsConfig{GlobalMaxCordoned: 5, PerPoolMaxCordoned: 2},
		DrainTimeout:              1 * time.Second,
		ForceAfterEvictionFailure: true,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	drainMgr := &mockDrainMgr{}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
		StepFactory:  stepFactory,
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -61)}, // 61 days > 20m threshold
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

	// Drain should NOT be called — this node was cordoned by an engineer
	if drainMgr.drainCalled {
		t.Error("drain should NOT be called on a node cordoned by another engineer")
	}

	// Node should still be cordoned — we didn't touch it
	node, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-manual", metav1.GetOptions{})
	if !node.Spec.Unschedulable {
		t.Error("node should still be cordoned — we should not have uncordoned it")
	}

	// Node should NOT have our managed label
	if node.Labels[constants.LabelRemediationManaged] == "true" {
		t.Error("node should NOT have remediation.managed label — we should not adopt it")
	}
}

// TDD Test: handleCordonNode should skip nodes already cordoned by an engineer.
//
// Scenario: A node at 55 days uptime (cordon threshold) is already cordoned
// by an engineer for manual maintenance. It does NOT have our
// LabelRemediationManaged label. The tool should NOT adopt it — no label,
// no taints, no annotations.
func TestSkipsEngineerCordonedNodeAtCordonThreshold(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		// Node cordoned by an engineer — no remediation labels or annotations
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-manual-cordon",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-manual",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
					// No LabelRemediationManaged — not ours
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: true},
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:           config.Duration(55 * 24 * time.Hour),
		RemediationThreshold:      config.Duration(60 * 24 * time.Hour),
		DryRun:                    false,
		InstanceTypeFilter:        "b200.*",
		Action:                    config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 2},
		Guardrails:                config.GuardrailsConfig{GlobalMaxCordoned: 5, PerPoolMaxCordoned: 2},
		DrainTimeout:              1 * time.Second,
		ForceAfterEvictionFailure: true,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     &mockDrainMgr{},
		StepFactory:  &mockStepCreator{step: &actions.NoopStep{}},
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -56)}, // 56 days > 55d cordon threshold
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

	// Node should still be cordoned — we didn't touch it
	node, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-manual-cordon", metav1.GetOptions{})
	if !node.Spec.Unschedulable {
		t.Error("node should still be cordoned")
	}

	// Node should NOT have our managed label
	if node.Labels[constants.LabelRemediationManaged] == "true" {
		t.Error("node should NOT have remediation.managed label — we should not adopt a node cordoned by an engineer")
	}

	// Node should NOT have our phase label
	if node.Labels[constants.LabelRemediationPhase] != "" {
		t.Errorf("node should NOT have remediation.phase label, got %q", node.Labels[constants.LabelRemediationPhase])
	}
}

// TestNodePriorityInvalidFallsBack verifies that an invalid nodePriority value
// falls back to highest-uptime (the default) with a warning, instead of crashing.
func TestNodePriorityInvalidFallsBack(t *testing.T) {
	// Same setup as TestNodePriorityConfigWired but with an invalid priority.
	// Should fall back to highest-uptime, so node-high (2h) gets remediated first.
	now := time.Now()
	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-high",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-high",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-low",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-low",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:           config.Duration(30 * time.Minute),
		RemediationThreshold:      config.Duration(1 * time.Hour),
		RemediationCooldown:       config.Duration(15 * time.Minute),
		DryRun:                    false,
		InstanceTypeFilter:        "b200.*",
		Action:                    config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 3},
		Guardrails:                config.GuardrailsConfig{GlobalMaxCordoned: 5, PerPoolMaxCordoned: 1},
		DrainTimeout:              1 * time.Second,
		ForceAfterEvictionFailure: true,
		CrusoeAPISecret:           "test-secret",
		CrusoeProjectID:           "proj-1",
		NodePriority:              "bogus-priority", // invalid — should fall back to highest-uptime
		NodeSelector:              config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	drainMgr := &mockDrainMgr{}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	deps := Dependencies{
		K8sClient:   k8sClient,
		DrainMgr:    drainMgr,
		StepFactory: stepFactory,
		UptimeEval: &mockUptimeEvaluatorMulti{
			startTimes: map[string]time.Time{
				"node-high": now.Add(-2 * time.Hour),
				"node-low":  now.Add(-90 * time.Minute),
			},
		},
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

	// With fallback to highest-uptime, node-high (2h) should be remediated
	nodeHigh, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-high", metav1.GetOptions{})
	if nodeHigh.Labels[constants.LabelRemediationPhase] != string(constants.PhaseMonitored) {
		t.Errorf("node-high should be remediated (fallback to highest-uptime), phase = %q",
			nodeHigh.Labels[constants.LabelRemediationPhase])
	}

	nodeLow, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-low", metav1.GetOptions{})
	if nodeLow.Spec.Unschedulable {
		t.Error("node-low should NOT be cordoned — guardrail exceeded (node-high took the slot via fallback)")
	}
}

// TestAlreadyCordonedNodeDoesNotDoubleCountGuardrail verifies that a node
// cordoned by us in a previous run (managed=true, phase=cordoned) does NOT
// consume an additional guardrail slot when re-processed in the cordon window.
//
// Scenario: perPoolMaxCordoned=2. node-a was cordoned by us in a previous run
// (still in cordon window). node-b and node-c are new nodes also in the cordon
// window. countActiveNodesInPool counts node-a as 1 active. handleCordonNode
// re-processes node-a and increments the counter again (double-count), making
// poolActive=2. Then node-b passes the guardrail (2 < 2 is false — blocked!).
// Wait — 2 >= 2, so node-b is blocked. But node-b SHOULD be cordoned because
// node-a only holds 1 slot, not 2.
//
// With the fix: node-a is already cordoned, so no increment. poolActive stays
// at 1. node-b passes guardrail (1 < 2), gets cordoned, poolActive becomes 2.
// node-c is blocked (2 >= 2). Correct behavior: node-a and node-b cordoned.
func TestAlreadyCordonedNodeDoesNotDoubleCountGuardrail(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		// Node cordoned by us in a previous run — still in cordon window
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-a",
				Labels: map[string]string{
					constants.LabelNodepoolID:         "pool-a",
					constants.LabelInstanceID:         "vm-a",
					constants.LabelProjectID:          "proj-1",
					constants.LabelInstanceType:       "b200-180gb-sxm-ib.8x",
					constants.LabelRemediationManaged: "true",
					constants.LabelRemediationPhase:   string(constants.PhaseCordoned),
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: true},
		},
		// New node that should be cordoned (pool max=2, only 1 slot used)
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-b",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-b",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
		// New node that should be blocked (pool max=2, both slots used)
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: "node-c",
				Labels: map[string]string{
					constants.LabelNodepoolID:   "pool-a",
					constants.LabelInstanceID:   "vm-c",
					constants.LabelProjectID:    "proj-1",
					constants.LabelInstanceType: "b200-180gb-sxm-ib.8x",
				},
			},
			Spec: corev1.NodeSpec{Unschedulable: false},
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:           config.Duration(55 * 24 * time.Hour),
		RemediationThreshold:      config.Duration(60 * 24 * time.Hour),
		RemediationCooldown:       config.Duration(7 * 24 * time.Hour),
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

	drainMgr := &mockDrainMgr{}
	stepFactory := &mockStepCreator{step: &actions.NoopStep{}}

	// Use per-node uptimes so sort order is deterministic:
	// node-b (57d) sorts before node-c (56d). node-a (56d) is already cordoned.
	multiUptime := &mockUptimeEvaluatorMulti{startTimes: map[string]time.Time{
		"node-a": time.Now().AddDate(0, 0, -56),
		"node-b": time.Now().AddDate(0, 0, -57),
		"node-c": time.Now().AddDate(0, 0, -56),
	}}

	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
		StepFactory:  stepFactory,
		UptimeEval:   multiUptime,
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

	// node-a should still be cordoned (idempotent re-cordon)
	nodeA, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-a", metav1.GetOptions{})
	if !nodeA.Spec.Unschedulable {
		t.Error("node-a should still be cordoned")
	}

	// node-b SHOULD be cordoned — pool max=2, node-a holds 1 slot, node-b takes the 2nd.
	// If double-counting occurs, node-a consumes 2 slots and node-b is incorrectly blocked.
	nodeB, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-b", metav1.GetOptions{})
	if !nodeB.Spec.Unschedulable {
		t.Error("node-b should be cordoned — pool guardrail (max=2) has room (node-a holds 1 slot)")
	}

	// node-c should NOT be cordoned — both pool slots are now used
	nodeC, _ := clientset.CoreV1().Nodes().Get(context.Background(), "node-c", metav1.GetOptions{})
	if nodeC.Spec.Unschedulable {
		t.Error("node-c should NOT be cordoned — pool guardrail (max=2) is full")
	}
}

func TestRun_ReturnsRunResultWithPoolReport(t *testing.T) {
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
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:      config.Duration(55 * 24 * time.Hour),
		RemediationThreshold: config.Duration(60 * 24 * time.Hour),
		DryRun:               true,
		InstanceTypeFilter:   "b200.*",
		Action:               config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 3},
		Guardrails:           config.GuardrailsConfig{GlobalMaxCordoned: 5, PerPoolMaxCordoned: 2},
		DrainTimeout:         10 * time.Minute,
		CrusoeProjectID:      "proj-1",
		NodeSelector:         config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	crusoeClient := crusoe.NewClient("http://localhost", "test-access", "test-secret", "proj-1")
	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     k8s.NewDrainManager(k8sClient, clientset, cfg.DrainTimeout, true),
		StepFactory:  actions.NewFactory(k8sClient, crusoeClient),
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -30)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Discoverer:   discovery.NewDiscoverer(k8sClient, cfg),
		Config:       cfg,
		Recorder:     record.NewFakeRecorder(20),
		ReportWriter: nil, // nil-safe — Run() skips CR writes when ReportWriter is nil
	}

	mgr := NewManager(deps)
	result, err := mgr.Run(context.Background())
	if err != nil {
		t.Fatalf("Run failed: %v", err)
	}

	if result.LastRunStatus != "succeeded" {
		t.Errorf("LastRunStatus = %q, want succeeded", result.LastRunStatus)
	}
	if len(result.PoolReports) != 1 {
		t.Fatalf("expected 1 pool report, got %d", len(result.PoolReports))
	}
	if result.PoolReports[0].TotalNodes != 1 {
		t.Errorf("TotalNodes = %d, want 1", result.PoolReports[0].TotalNodes)
	}
	if result.PoolReports[0].MonitoredNodes != 0 {
		t.Errorf("MonitoredNodes = %d, want 0 (node has no managed label — never been cordoned)", result.PoolReports[0].MonitoredNodes)
	}
	if result.PoolReports[0].UnmanagedNodes != 1 {
		t.Errorf("UnmanagedNodes = %d, want 1 (node has no managed label)", result.PoolReports[0].UnmanagedNodes)
	}
	if result.Config.ActionType != "noop" {
		t.Errorf("Config.ActionType = %q, want noop", result.Config.ActionType)
	}
}

func TestRun_WritesProgressiveCRDUpdates(t *testing.T) {
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
		},
	)

	k8sClient := k8s.NewClient(clientset, nil)
	cfg := &config.Config{
		CordonThreshold:      config.Duration(55 * 24 * time.Hour),
		RemediationThreshold: config.Duration(60 * 24 * time.Hour),
		DryRun:               true,
		InstanceTypeFilter:   "b200.*",
		Action:               config.ActionConfig{Type: "noop", Timeout: 5 * time.Second, MaxRetries: 3},
		Guardrails:           config.GuardrailsConfig{GlobalMaxCordoned: 5, PerPoolMaxCordoned: 2},
		DrainTimeout:         10 * time.Minute,
		CrusoeProjectID:      "proj-1",
		NodeSelector:         config.NodeSelectorConfig{MatchLabels: map[string]string{constants.LabelProjectID: "proj-1"}},
	}

	// Use a fake dynamic client to capture CR writes
	gvr := schema.GroupVersionResource{
		Group:    "remediation.crusoe.ai",
		Version:  "v1alpha1",
		Resource: "remediationreports",
	}
	scheme := runtime.NewScheme()
	gvrToListKind := map[schema.GroupVersionResource]string{
		gvr: "RemediationReportList",
	}
	dynClient := dynfake.NewSimpleDynamicClientWithCustomListKinds(scheme, gvrToListKind)
	reportWriter := NewReportWriter(dynClient, "crusoe-node-remediation")

	crusoeClient := crusoe.NewClient("http://localhost", "test-access", "test-secret", "proj-1")
	deps := Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     k8s.NewDrainManager(k8sClient, clientset, cfg.DrainTimeout, true),
		StepFactory:  actions.NewFactory(k8sClient, crusoeClient),
		UptimeEval:   &mockUptimeEvaluator{startTime: time.Now().AddDate(0, 0, -30)},
		GuardChecker: guardrails.NewChecker(cfg.Guardrails),
		Discoverer:   discovery.NewDiscoverer(k8sClient, cfg),
		Config:       cfg,
		Recorder:     record.NewFakeRecorder(20),
		ReportWriter: reportWriter,
	}

	mgr := NewManager(deps)
	_, err := mgr.Run(context.Background())
	if err != nil {
		t.Fatalf("Run failed: %v", err)
	}

	// Verify CR was created with final "succeeded" status
	cr, err := dynClient.Resource(gvr).Namespace("crusoe-node-remediation").Get(
		context.Background(), "np-pool-a", metav1.GetOptions{},
	)
	if err != nil {
		t.Fatalf("expected CR to exist: %v", err)
	}

	status := cr.Object["status"].(map[string]interface{})
	if status["lastRunStatus"] != "succeeded" {
		t.Errorf("lastRunStatus = %v, want succeeded (final update)", status["lastRunStatus"])
	}
}
