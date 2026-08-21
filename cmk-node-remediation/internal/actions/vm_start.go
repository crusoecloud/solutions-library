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

// VMStartStep starts a VM via the Crusoe API and waits for the node to become Ready.
// Idempotent: if the VM is already running and node is Ready, it skips.
// Two-phase verification: (1) poll Crusoe operation completion, (2) poll K8s bootID + Ready.
type VMStartStep struct {
	crusoeClient *crusoe.Client
	k8sClient    *k8s.Client
	bootVerifier *helpers.BootVerifier
	timeout      time.Duration
	maxRetries   int
}

func (s *VMStartStep) Type() string { return "vm-start" }

func (s *VMStartStep) Run(ctx context.Context, node NodeInfo, params map[string]string) error {
	// 1. Idempotency check: is VM already running and node Ready?
	state, err := s.crusoeClient.GetVMState(ctx, node.InstanceID)
	if err == nil && state == "STATE_RUNNING" {
		k8sNode, err := s.k8sClient.GetNode(ctx, node.Name)
		if err == nil && k8s.IsNodeReady(k8sNode) {
			log.Printf("step vm-start: VM %s already running and node Ready, skipping", node.InstanceID)
			return nil
		}
	}

	// 2. Capture bootID before start
	oldBootID := ""
	if k8sNode, err := s.k8sClient.GetNode(ctx, node.Name); err == nil {
		oldBootID = k8sNode.Status.NodeInfo.BootID
	}

	// 3. Act + verify with retries
	var lastErr error
	for attempt := 1; attempt <= s.maxRetries; attempt++ {
		log.Printf("step vm-start: attempt %d/%d for VM %s", attempt, s.maxRetries, node.InstanceID)

		// Phase 1: Call Crusoe API START
		opID, err := s.crusoeClient.StartVM(ctx, node.InstanceID)
		if err != nil {
			lastErr = err
			log.Printf("step vm-start: Crusoe API call failed (attempt %d): %v", attempt, err)
			sleepOrCancel(ctx, time.Duration(1<<uint(attempt-1))*time.Second)
			continue
		}

		// Phase 1: Poll operation completion
		if opID != "" {
			if err := s.crusoeClient.WaitForOperation(ctx, opID, s.timeout); err != nil {
				lastErr = err
				log.Printf("step vm-start: operation wait failed (attempt %d): %v", attempt, err)
				continue
			}
		}

		// Phase 2: Verify boot happened + node is Ready
		if err := s.bootVerifier.VerifyBootAndReady(ctx, node.Name, oldBootID, s.timeout); err != nil {
			lastErr = err
			log.Printf("step vm-start: boot verification failed (attempt %d): %v", attempt, err)
			continue
		}

		return nil
	}

	return fmt.Errorf("step vm-start failed after %d attempts: %w", s.maxRetries, lastErr)
}
