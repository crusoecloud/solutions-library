package actions

import (
	"context"
	"fmt"
	"log"
	"time"

	"crusoe-node-remediation/internal/crusoe"
	"crusoe-node-remediation/internal/k8s"
)

// VMDeleteStep deletes a VM via the Crusoe API.
// Idempotent: if the VM is already gone (404), it skips.
// Two-phase verification: (1) poll Crusoe operation completion, (2) wait for VM to be gone.
// Note: After delete, the old node object may linger. The remediation manager handles
// the case where the old node is gone (don't uncordon).
type VMDeleteStep struct {
	crusoeClient *crusoe.Client
	k8sClient    *k8s.Client
	timeout      time.Duration
	maxRetries   int
}

func (s *VMDeleteStep) Type() string { return "vm-delete" }

func (s *VMDeleteStep) Run(ctx context.Context, node NodeInfo, params map[string]string) error {
	// 1. Idempotency check: does VM still exist?
	_, err := s.crusoeClient.GetVMState(ctx, node.InstanceID)
	if err != nil {
		if crusoe.IsNotFoundError(err) {
			// VM not found — already deleted
			log.Printf("step vm-delete: VM %s not found, already deleted, skipping", node.InstanceID)
			return nil
		}
		// Other API error (500, network, auth) — don't skip, proceed with delete
		log.Printf("step vm-delete: warning: failed to check VM %s state: %v (proceeding with delete)", node.InstanceID, err)
	}

	// 2. Act + verify with retries
	var lastErr error
	for attempt := 1; attempt <= s.maxRetries; attempt++ {
		log.Printf("step vm-delete: attempt %d/%d for VM %s", attempt, s.maxRetries, node.InstanceID)

		// Phase 1: Call Crusoe API DELETE
		opID, err := s.crusoeClient.DeleteVM(ctx, node.InstanceID)
		if err != nil {
			lastErr = err
			log.Printf("step vm-delete: Crusoe API call failed (attempt %d): %v", attempt, err)
			sleepOrCancel(ctx, time.Duration(1<<uint(attempt-1))*time.Second)
			continue
		}

		// Phase 1: Poll operation completion
		if opID != "" {
			if err := s.crusoeClient.WaitForOperation(ctx, opID, s.timeout); err != nil {
				lastErr = err
				log.Printf("step vm-delete: operation wait failed (attempt %d): %v", attempt, err)
				continue
			}
		}

		// Phase 2: Verify VM is gone
		_, err = s.crusoeClient.GetVMState(ctx, node.InstanceID)
		if err != nil {
			log.Printf("step vm-delete: VM %s deleted successfully", node.InstanceID)
			return nil
		}

		lastErr = fmt.Errorf("VM %s still exists after delete", node.InstanceID)
		log.Printf("step vm-delete: VM still exists (attempt %d)", attempt)
		sleepOrCancel(ctx, time.Duration(1<<uint(attempt-1))*time.Second)
	}

	return fmt.Errorf("step vm-delete failed after %d attempts: %w", s.maxRetries, lastErr)
}
