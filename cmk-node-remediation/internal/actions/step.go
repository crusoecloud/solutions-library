package actions

import (
	"context"
	"fmt"
	"log"
	"time"

	"crusoe-node-remediation/internal/actions/helpers"
	"crusoe-node-remediation/internal/config"
	"crusoe-node-remediation/internal/crusoe"
	"crusoe-node-remediation/internal/k8s"
)

// NodeInfo holds metadata about a node being remediated.
type NodeInfo struct {
	Name       string
	InstanceID string
}

// Step is a single remediation operation. A sequence of steps is also a Step.
// Each step must be idempotent — safe to call multiple times.
type Step interface {
	// Run performs the remediation operation and waits for completion.
	// Must check current state first and skip if already in desired state.
	Run(ctx context.Context, node NodeInfo, params map[string]string) error
	// Type returns the step type name.
	Type() string
}

// Steps is a sequence of steps with optional waits between them.
// It implements Step — steps IS a step (composite pattern).
type Steps struct {
	steps        []Step
	waitsBetween []time.Duration
}

func (s *Steps) Type() string { return "steps" }

func (s *Steps) Run(ctx context.Context, node NodeInfo, params map[string]string) error {
	for i, step := range s.steps {
		log.Printf("running step %d/%d: %s for node %s", i+1, len(s.steps), step.Type(), node.Name)
		if err := step.Run(ctx, node, params); err != nil {
			return fmt.Errorf("step %d (%s) failed: %w", i+1, step.Type(), err)
		}
		if i < len(s.waitsBetween) && s.waitsBetween[i] > 0 {
			log.Printf("waiting %v after step %s", s.waitsBetween[i], step.Type())
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(s.waitsBetween[i]):
			}
		}
	}
	return nil
}

// Factory creates steps by type and builds Steps composites from config.
type Factory struct {
	k8sClient    *k8s.Client
	crusoeClient *crusoe.Client
}

// NewFactory creates a new step factory with all built-in steps registered.
func NewFactory(k8sClient *k8s.Client, crusoeClient *crusoe.Client) *Factory {
	return &Factory{
		k8sClient:    k8sClient,
		crusoeClient: crusoeClient,
	}
}

// Create returns a Step for the given action type.
func (f *Factory) Create(stepType string, timeout time.Duration, maxRetries int) (Step, error) {
	switch stepType {
	case "vm-reset":
		return &VMResetStep{
			crusoeClient: f.crusoeClient,
			k8sClient:    f.k8sClient,
			bootVerifier: helpers.NewBootVerifier(f.k8sClient),
			timeout:      timeout,
			maxRetries:   maxRetries,
		}, nil
	case "vm-stop":
		return &VMStopStep{
			crusoeClient: f.crusoeClient,
			timeout:      timeout,
			maxRetries:   maxRetries,
		}, nil
	case "vm-start":
		return &VMStartStep{
			crusoeClient: f.crusoeClient,
			k8sClient:    f.k8sClient,
			bootVerifier: helpers.NewBootVerifier(f.k8sClient),
			timeout:      timeout,
			maxRetries:   maxRetries,
		}, nil
	case "vm-delete":
		return &VMDeleteStep{
			crusoeClient: f.crusoeClient,
			k8sClient:    f.k8sClient,
			timeout:      timeout,
			maxRetries:   maxRetries,
		}, nil
	case "noop":
		return &NoopStep{}, nil
	default:
		return nil, fmt.Errorf("unknown step type: %q", stepType)
	}
}

// CreateFromConfig builds a single Step or a Steps composite from ActionConfig.
func (f *Factory) CreateFromConfig(cfg config.ActionConfig) (Step, error) {
	if len(cfg.Steps) > 0 {
		// Multi-step sequence
		var steps []Step
		var waits []time.Duration
		for _, sc := range cfg.Steps {
			step, err := f.Create(sc.Type, sc.Timeout, cfg.MaxRetries)
			if err != nil {
				return nil, err
			}
			steps = append(steps, step)
			waits = append(waits, sc.Wait)
		}
		return &Steps{steps: steps, waitsBetween: waits}, nil
	}

	// Single step
	return f.Create(cfg.Type, cfg.Timeout, cfg.MaxRetries)
}

// sleepOrCancel sleeps for the given duration or returns on context cancellation.
func sleepOrCancel(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}
