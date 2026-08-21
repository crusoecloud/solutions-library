package k8s

import (
	"context"
	"fmt"
	"io"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/kubectl/pkg/drain"
)

// DrainManager handles node draining using k8s.io/kubectl/pkg/drain.
type DrainManager struct {
	client            *Client
	clientset         kubernetes.Interface
	timeout           time.Duration
	forceAfterTimeout bool
}

func NewDrainManager(client *Client, clientset kubernetes.Interface, timeout time.Duration, forceAfterTimeout bool) *DrainManager {
	return &DrainManager{
		client:            client,
		clientset:         clientset,
		timeout:           timeout,
		forceAfterTimeout: forceAfterTimeout,
	}
}

// Drain evicts all evictable pods from a node, respecting PDBs.
func (dm *DrainManager) Drain(ctx context.Context, nodeName string) error {
	return dm.runDrain(ctx, nodeName, false)
}

// ForceAfterEvictionFailure evicts all evictable pods from a node, ignoring PDBs.
func (dm *DrainManager) ForceAfterEvictionFailure(ctx context.Context, nodeName string) error {
	return dm.runDrain(ctx, nodeName, true)
}

func (dm *DrainManager) runDrain(ctx context.Context, nodeName string, force bool) error {
	// Drain configuration mirrors the recommended kubectl drain flags:
	//   kubectl drain --delete-emptydir-data --ignore-daemonsets <node>
	//
	// DeleteEmptyDirData: Continue evicting even if pods use emptyDir volumes
	//   (local data that is deleted when the pod is removed). This is safe for
	//   stateless pods like victoria-metrics-agent whose emptyDir is only a
	//   transient scrape buffer. Without this, drain fails with:
	//     "cannot delete Pods with local storage (use --delete-emptydir-data
	//     to override)"
	//   See: https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/
	//
	// IgnoreAllDaemonSets: Skip DaemonSet-managed pods. The DaemonSet controller
	//   immediately recreates them on the node, so evicting is pointless.
	//
	// GracePeriodSeconds: -1 uses each pod's configured grace period.
	drainer := &drain.Helper{
		Ctx:                 ctx,
		Client:              dm.clientset,
		Force:               force,
		GracePeriodSeconds:  -1,
		IgnoreAllDaemonSets: true,
		DeleteEmptyDirData:  true,
		Timeout:             dm.timeout,
		Out:                 io.Discard,
		ErrOut:              io.Discard,
	}

	if force {
		// Force drain: bypass PDBs by using delete instead of eviction.
		// DeleteEmptyDirData is already set above (shared with graceful drain).
		drainer.DisableEviction = true
	}

	node, err := dm.clientset.CoreV1().Nodes().Get(ctx, nodeName, metav1.GetOptions{})
	if err != nil {
		return fmt.Errorf("failed to get node %s for drain: %w", nodeName, err)
	}

	if err := drain.RunCordonOrUncordon(drainer, node, true); err != nil {
		return fmt.Errorf("failed to cordon node %s during drain: %w", nodeName, err)
	}

	if err := drain.RunNodeDrain(drainer, nodeName); err != nil {
		return fmt.Errorf("failed to drain node %s: %w", nodeName, err)
	}

	return nil
}
