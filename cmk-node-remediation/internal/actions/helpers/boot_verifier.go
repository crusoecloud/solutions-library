package helpers

import (
	"context"
	"fmt"
	"log"
	"time"

	"crusoe-node-remediation/internal/k8s"
)

// sleepOrCancel sleeps for the given duration or returns on context cancellation.
func sleepOrCancel(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}

// BootVerifier helps steps confirm that a node rebooted.
// Steps capture the bootID before their action, then call VerifyBoot
// to poll until the bootID changes (confirming a boot occurred).
type BootVerifier struct {
	k8sClient *k8s.Client
}

func NewBootVerifier(k8sClient *k8s.Client) *BootVerifier {
	return &BootVerifier{k8sClient: k8sClient}
}

// CaptureBootID returns the current bootID from the node object.
// Call this BEFORE the action (reset, start, delete).
func (v *BootVerifier) CaptureBootID(ctx context.Context, nodeName string) (string, error) {
	node, err := v.k8sClient.GetNode(ctx, nodeName)
	if err != nil {
		return "", err
	}
	return node.Status.NodeInfo.BootID, nil
}

// VerifyBoot polls until the node's bootID differs from the given one,
// confirming a boot occurred. Returns the new bootID.
func (v *BootVerifier) VerifyBoot(ctx context.Context, nodeName, oldBootID string, timeout time.Duration) (string, error) {
	log.Printf("boot verifier: waiting for bootID change on node %s (old=%s, timeout=%s)", nodeName, oldBootID, timeout)
	deadline := time.Now().Add(timeout)
	pollInterval := 10 * time.Second

	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		default:
		}

		node, err := v.k8sClient.GetNode(ctx, nodeName)
		if err != nil {
			// Node might be temporarily unreachable during reboot
			log.Printf("boot verifier: failed to get node %s: %v", nodeName, err)
			sleepOrCancel(ctx, pollInterval)
			continue
		}

		newBootID := node.Status.NodeInfo.BootID
		if newBootID != "" && newBootID != oldBootID {
			log.Printf("boot verifier: bootID changed on node %s (old=%s, new=%s)", nodeName, oldBootID, newBootID)
			return newBootID, nil
		}

		log.Printf("boot verifier: node %s bootID unchanged (current=%s), polling...", nodeName, newBootID)
		sleepOrCancel(ctx, pollInterval)
	}

	return "", fmt.Errorf("node %s bootID did not change within %v", nodeName, timeout)
}

// VerifyBootAndReady polls until bootID changes AND node is Ready.
// Uses a single shared deadline so total wait never exceeds the configured timeout.
func (v *BootVerifier) VerifyBootAndReady(ctx context.Context, nodeName, oldBootID string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)

	// First: wait for bootID to change (boot happened)
	if _, err := v.verifyBootWithDeadline(ctx, nodeName, oldBootID, deadline); err != nil {
		return err
	}

	// Second: wait for node Ready (boot completed) — uses remaining time
	remaining := time.Until(deadline)
	if remaining <= 0 {
		return fmt.Errorf("node %s did not become Ready within %v", nodeName, timeout)
	}

	log.Printf("boot verifier: waiting for node %s to become Ready", nodeName)
	pollInterval := 30 * time.Second
	// Use shorter poll interval if timeout is short (for testing)
	if remaining < pollInterval {
		pollInterval = remaining / 3
		if pollInterval < 100*time.Millisecond {
			pollInterval = 100 * time.Millisecond
		}
	}

	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		node, err := v.k8sClient.GetNode(ctx, nodeName)
		if err != nil {
			sleepOrCancel(ctx, pollInterval)
			continue
		}

		if k8s.IsNodeReady(node) {
			log.Printf("boot verifier: node %s is Ready", nodeName)
			return nil
		}

		sleepOrCancel(ctx, pollInterval)
	}

	return fmt.Errorf("node %s did not become Ready within %v", nodeName, timeout)
}

// verifyBootWithDeadline is like VerifyBoot but uses an explicit deadline
// instead of computing one from a timeout. This allows VerifyBootAndReady
// to share a single deadline across both phases.
func (v *BootVerifier) verifyBootWithDeadline(ctx context.Context, nodeName, oldBootID string, deadline time.Time) (string, error) {
	log.Printf("boot verifier: waiting for bootID change on node %s (old=%s, deadline=%s)", nodeName, oldBootID, deadline.Format(time.RFC3339))
	pollInterval := 10 * time.Second

	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		default:
		}

		node, err := v.k8sClient.GetNode(ctx, nodeName)
		if err != nil {
			// Node might be temporarily unreachable during reboot
			log.Printf("boot verifier: failed to get node %s: %v", nodeName, err)
			sleepOrCancel(ctx, pollInterval)
			continue
		}

		newBootID := node.Status.NodeInfo.BootID
		if newBootID != "" && newBootID != oldBootID {
			log.Printf("boot verifier: bootID changed on node %s (old=%s, new=%s)", nodeName, oldBootID, newBootID)
			return newBootID, nil
		}

		log.Printf("boot verifier: node %s bootID unchanged (current=%s), polling...", nodeName, newBootID)
		sleepOrCancel(ctx, pollInterval)
	}

	return "", fmt.Errorf("node %s bootID did not change before deadline", nodeName)
}
