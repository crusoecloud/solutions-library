package actions

import (
	"context"
	"fmt"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"

	"crusoe-node-remediation/internal/actions/helpers"
	"crusoe-node-remediation/internal/config"
	"crusoe-node-remediation/internal/crusoe"
	"crusoe-node-remediation/internal/k8s"
)

func TestNoopStep(t *testing.T) {
	step := &NoopStep{}
	nodeInfo := NodeInfo{Name: "node-1", InstanceID: "vm-001"}

	if step.Type() != "noop" {
		t.Errorf("Type() = %q, want %q", step.Type(), "noop")
	}

	if err := step.Run(context.Background(), nodeInfo, nil); err != nil {
		t.Fatalf("Run failed: %v", err)
	}
}

func TestVMResetStepType(t *testing.T) {
	step := &VMResetStep{}
	if step.Type() != "vm-reset" {
		t.Errorf("Type() = %q, want %q", step.Type(), "vm-reset")
	}
}

func TestVMResetStepRequiresNode(t *testing.T) {
	// VMResetStep should NOT skip based on Ready status — it always proceeds.
	// The remediationCooldown check in the lifecycle manager handles "already remediated".
	// This test verifies the step fails gracefully if the node doesn't exist.
	clientset := fake.NewSimpleClientset() // no nodes
	k8sClient := k8s.NewClient(clientset, nil)
	crusoeClient := crusoe.NewClient("http://localhost", "test-access", "test-secret", "proj-1")

	step := &VMResetStep{
		crusoeClient: crusoeClient,
		k8sClient:    k8sClient,
		bootVerifier: helpers.NewBootVerifier(k8sClient),
		timeout:      5 * time.Second,
		maxRetries:   3,
	}

	nodeInfo := NodeInfo{Name: "nonexistent-node", InstanceID: "vm-001"}
	err := step.Run(context.Background(), nodeInfo, nil)
	if err == nil {
		t.Fatal("Run should fail when node doesn't exist")
	}
}

func TestFactoryCreatesSingleStep(t *testing.T) {
	clientset := fake.NewSimpleClientset()
	k8sClient := k8s.NewClient(clientset, nil)
	crusoeClient := crusoe.NewClient("http://localhost", "test-access", "test-secret", "proj-1")

	factory := NewFactory(k8sClient, crusoeClient)
	step, err := factory.Create("noop", 30*time.Second, 3)
	if err != nil {
		t.Fatalf("Create(noop) failed: %v", err)
	}
	if step.Type() != "noop" {
		t.Errorf("step type = %q, want noop", step.Type())
	}
}

func TestFactoryCreatesInvalidType(t *testing.T) {
	clientset := fake.NewSimpleClientset()
	k8sClient := k8s.NewClient(clientset, nil)
	crusoeClient := crusoe.NewClient("http://localhost", "test-access", "test-secret", "proj-1")

	factory := NewFactory(k8sClient, crusoeClient)
	_, err := factory.Create("invalid", 30*time.Second, 3)
	if err == nil {
		t.Fatal("expected error for invalid step type")
	}
}

func TestStepsComposite(t *testing.T) {
	noop1 := &NoopStep{}
	noop2 := &NoopStep{}

	steps := &Steps{
		steps: []Step{noop1, noop2},
	}

	if steps.Type() != "steps" {
		t.Errorf("Type() = %q, want steps", steps.Type())
	}

	err := steps.Run(context.Background(), NodeInfo{Name: "node-1"}, nil)
	if err != nil {
		t.Fatalf("Steps.Run failed: %v", err)
	}
}

func TestBootVerifierCaptureBootID(t *testing.T) {
	clientset := fake.NewSimpleClientset(
		&corev1.Node{
			ObjectMeta: metav1.ObjectMeta{Name: "node-1"},
			Status: corev1.NodeStatus{
				NodeInfo: corev1.NodeSystemInfo{BootID: "boot-abc"},
			},
		},
	)
	k8sClient := k8s.NewClient(clientset, nil)
	bv := helpers.NewBootVerifier(k8sClient)

	bootID, err := bv.CaptureBootID(context.Background(), "node-1")
	if err != nil {
		t.Fatalf("CaptureBootID failed: %v", err)
	}
	if bootID != "boot-abc" {
		t.Errorf("bootID = %q, want boot-abc", bootID)
	}
}

// TDD Test: CreateFromConfig with multi-step builds Steps composite
func TestCreateFromConfigMultiStep(t *testing.T) {
	clientset := fake.NewSimpleClientset()
	k8sClient := k8s.NewClient(clientset, nil)
	crusoeClient := crusoe.NewClient("http://localhost", "test-access", "test-secret", "proj-1")
	factory := NewFactory(k8sClient, crusoeClient)

	cfg := config.ActionConfig{
		MaxRetries: 3,
		Steps: []config.ActionStepConfig{
			{Type: "vm-stop", Timeout: 5 * time.Minute},
			{Type: "vm-delete", Timeout: 30 * time.Minute, Wait: 2 * time.Minute},
		},
	}

	step, err := factory.CreateFromConfig(cfg)
	if err != nil {
		t.Fatalf("CreateFromConfig failed: %v", err)
	}

	if step.Type() != "steps" {
		t.Errorf("step type = %q, want steps", step.Type())
	}

	// Verify it's a Steps composite with 2 sub-steps
	steps, ok := step.(*Steps)
	if !ok {
		t.Fatalf("expected *Steps, got %T", step)
	}
	if len(steps.steps) != 2 {
		t.Fatalf("expected 2 sub-steps, got %d", len(steps.steps))
	}
	if steps.steps[0].Type() != "vm-stop" {
		t.Errorf("step 0 type = %q, want vm-stop", steps.steps[0].Type())
	}
	if steps.steps[1].Type() != "vm-delete" {
		t.Errorf("step 1 type = %q, want vm-delete", steps.steps[1].Type())
	}
	if len(steps.waitsBetween) != 2 {
		t.Fatalf("expected 2 wait entries, got %d", len(steps.waitsBetween))
	}
	if steps.waitsBetween[0] != 0 {
		t.Errorf("wait 0 = %v, want 0", steps.waitsBetween[0])
	}
	if steps.waitsBetween[1] != 2*time.Minute {
		t.Errorf("wait 1 = %v, want 2m", steps.waitsBetween[1])
	}
}

// TDD Test: CreateFromConfig with single step returns leaf Step
func TestCreateFromConfigSingleStep(t *testing.T) {
	clientset := fake.NewSimpleClientset()
	k8sClient := k8s.NewClient(clientset, nil)
	crusoeClient := crusoe.NewClient("http://localhost", "test-access", "test-secret", "proj-1")
	factory := NewFactory(k8sClient, crusoeClient)

	cfg := config.ActionConfig{
		Type:       "noop",
		Timeout:    30 * time.Second,
		MaxRetries: 3,
	}

	step, err := factory.CreateFromConfig(cfg)
	if err != nil {
		t.Fatalf("CreateFromConfig failed: %v", err)
	}

	if step.Type() != "noop" {
		t.Errorf("step type = %q, want noop", step.Type())
	}
}

// TDD Test: Steps composite with failing first step → remaining steps NOT run
func TestStepsFailingFirstStepStopsRemaining(t *testing.T) {
	callCount := 0
	failingStep := &countingStep{name: "failing", shouldFail: true, callCount: &callCount}
	secondStep := &countingStep{name: "second", shouldFail: false, callCount: &callCount}

	steps := &Steps{
		steps: []Step{failingStep, secondStep},
	}

	err := steps.Run(context.Background(), NodeInfo{Name: "node-1"}, nil)
	if err == nil {
		t.Fatal("Steps.Run should fail when first step fails")
	}

	// Only first step should have been called
	if callCount != 1 {
		t.Errorf("expected 1 step call, got %d (second step should NOT run after first fails)", callCount)
	}
}

// countingStep tracks how many times Run is called.
type countingStep struct {
	name       string
	shouldFail bool
	callCount  *int
}

func (s *countingStep) Type() string { return s.name }
func (s *countingStep) Run(ctx context.Context, node NodeInfo, params map[string]string) error {
	*s.callCount++
	if s.shouldFail {
		return fmt.Errorf("step %s intentionally failed", s.name)
	}
	return nil
}
