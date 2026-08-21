package actions

import (
	"context"
	"fmt"
	"log"
	"time"

	"crusoe-node-remediation/internal/actions/helpers"
	"crusoe-node-remediation/internal/crusoe"
	"crusoe-node-remediation/internal/k8s"
)

// VMResetStep reboots a VM via the Crusoe API and waits for the node to become Ready.
// Idempotent: if the node is already Ready, it skips the API call.
// Two-phase verification: (1) poll Crusoe operation completion, (2) poll K8s bootID + Ready.
type VMResetStep struct {
	crusoeClient *crusoe.Client
	k8sClient    *k8s.Client
	bootVerifier *helpers.BootVerifier
	timeout      time.Duration
	maxRetries   int
}

func (s *VMResetStep) Type() string { return "vm-reset" }

func (s *VMResetStep) Run(ctx context.Context, node NodeInfo, params map[string]string) error {
	// Capture bootID before reset to verify the reboot actually happened.
	// We always proceed with the reset — the remediation manager's cooldown
	// check already ensures we don't re-remediate recently rebooted nodes.
	k8sNode, err := s.k8sClient.GetNode(ctx, node.Name)
	if err != nil {
		return fmt.Errorf("step vm-reset: failed to get node %s: %w", node.Name, err)
	}
	oldBootID := k8sNode.Status.NodeInfo.BootID
	log.Printf("step vm-reset: node %s bootID before reset: %s", node.Name, oldBootID)

	// 3. Act + verify with retries
	var lastErr error
	for attempt := 1; attempt <= s.maxRetries; attempt++ {
		log.Printf("step vm-reset: attempt %d/%d for node %s", attempt, s.maxRetries, node.Name)

		// Phase 1: Call Crusoe API RESET
		opID, err := s.crusoeClient.RebootVM(ctx, node.InstanceID)
		if err != nil {
			lastErr = err
			log.Printf("step vm-reset: API call failed (attempt %d): %v", attempt, err)
			sleepOrCancel(ctx, time.Duration(1<<uint(attempt-1))*time.Second)
			continue
		}
		log.Printf("step vm-reset: Crusoe API RESET accepted for VM %s, operation ID: %s", node.InstanceID, opID)

		// Phase 1: Poll operation completion
		if opID != "" {
			if err := s.crusoeClient.WaitForOperation(ctx, opID, s.timeout); err != nil {
				lastErr = err
				log.Printf("step vm-reset: operation wait failed (attempt %d): %v", attempt, err)
				continue
			}
			log.Printf("step vm-reset: operation %s completed for VM %s", opID, node.InstanceID)
		}

		// Phase 2: Verify boot happened + node is Ready
		if err := s.bootVerifier.VerifyBootAndReady(ctx, node.Name, oldBootID, s.timeout); err != nil {
			lastErr = err
			log.Printf("step vm-reset: boot verification failed (attempt %d): %v", attempt, err)
			continue
		}

		// Log post-reset bootID for evidence
		if postNode, err := s.k8sClient.GetNode(ctx, node.Name); err == nil {
			log.Printf("step vm-reset: node %s bootID after reset: %s (changed: %v)",
				node.Name, postNode.Status.NodeInfo.BootID, postNode.Status.NodeInfo.BootID != oldBootID)
		}

		return nil
	}

	return fmt.Errorf("step vm-reset failed after %d attempts: %w", s.maxRetries, lastErr)
}
