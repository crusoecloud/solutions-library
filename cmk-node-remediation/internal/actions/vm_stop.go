package actions

import (
	"context"
	"fmt"
	"log"
	"time"

	"crusoe-node-remediation/internal/crusoe"
)

// VMStopStep stops a VM via the Crusoe API.
// Idempotent: if the VM is already stopped, it skips the API call.
// Two-phase verification: (1) poll Crusoe operation completion, (2) poll VM state = stopped.
type VMStopStep struct {
	crusoeClient *crusoe.Client
	timeout      time.Duration
	maxRetries   int
}

func (s *VMStopStep) Type() string { return "vm-stop" }

func (s *VMStopStep) Run(ctx context.Context, node NodeInfo, params map[string]string) error {
	// 1. Idempotency check: is VM already stopped?
	state, err := s.crusoeClient.GetVMState(ctx, node.InstanceID)
	if err == nil && state == "STATE_STOPPED" {
		log.Printf("step vm-stop: VM %s already stopped, skipping", node.InstanceID)
		return nil
	}

	// 2. Act + verify with retries
	var lastErr error
	for attempt := 1; attempt <= s.maxRetries; attempt++ {
		log.Printf("step vm-stop: attempt %d/%d for VM %s", attempt, s.maxRetries, node.InstanceID)

		// Phase 1: Call Crusoe API STOP
		opID, err := s.crusoeClient.StopVM(ctx, node.InstanceID)
		if err != nil {
			lastErr = err
			log.Printf("step vm-stop: Crusoe API call failed (attempt %d): %v", attempt, err)
			sleepOrCancel(ctx, time.Duration(1<<uint(attempt-1))*time.Second)
			continue
		}

		// Phase 1: Poll operation completion
		if opID != "" {
			if err := s.crusoeClient.WaitForOperation(ctx, opID, s.timeout); err != nil {
				lastErr = err
				log.Printf("step vm-stop: operation wait failed (attempt %d): %v", attempt, err)
				continue
			}
		}

		// Phase 2: Verify VM is stopped
		if err := s.waitForState(ctx, node.InstanceID, "STATE_STOPPED"); err != nil {
			lastErr = err
			log.Printf("step vm-stop: VM not stopped after Crusoe API call (attempt %d): %v", attempt, err)
			continue
		}

		return nil
	}

	return fmt.Errorf("step vm-stop failed after %d attempts: %w", s.maxRetries, lastErr)
}

func (s *VMStopStep) waitForState(ctx context.Context, instanceID, wantState string) error {
	deadline := time.Now().Add(s.timeout)
	pollInterval := 10 * time.Second

	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		state, err := s.crusoeClient.GetVMState(ctx, instanceID)
		if err != nil {
			log.Printf("warning: failed to get VM state for %s: %v", instanceID, err)
			sleepOrCancel(ctx, pollInterval)
			continue
		}

		if state == wantState {
			return nil
		}

		sleepOrCancel(ctx, pollInterval)
	}

	return fmt.Errorf("VM %s did not reach state %q within %v", instanceID, wantState, s.timeout)
}
