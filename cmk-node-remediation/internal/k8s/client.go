package k8s

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/record"
	"k8s.io/client-go/util/retry"
)

// metadataPatch builds a JSON merge patch for node metadata (labels or annotations).
// Uses json.Marshal to safely escape keys and values.
func metadataPatch(kind, key, value string) ([]byte, error) {
	patch := map[string]map[string]map[string]string{
		"metadata": {
			kind: {
				key: value,
			},
		},
	}
	return json.Marshal(patch)
}

// Client wraps the Kubernetes clientset for node operations.
type Client struct {
	clientset kubernetes.Interface
	recorder  record.EventRecorder
}

// NewClient creates a new K8s client.
func NewClient(clientset kubernetes.Interface, recorder record.EventRecorder) *Client {
	return &Client{clientset: clientset, recorder: recorder}
}

func (c *Client) Eventf(node *corev1.Node, eventType, reason, messageFmt string, args ...interface{}) {
	if c.recorder != nil {
		c.recorder.Eventf(node, eventType, reason, messageFmt, args...)
	}
}

func (c *Client) GetNode(ctx context.Context, nodeName string) (*corev1.Node, error) {
	node, err := c.clientset.CoreV1().Nodes().Get(ctx, nodeName, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("failed to get node %s: %w", nodeName, err)
	}
	return node, nil
}

func (c *Client) ListNodes(ctx context.Context, labelSelector string) (*corev1.NodeList, error) {
	listOpts := metav1.ListOptions{}
	if labelSelector != "" {
		listOpts.LabelSelector = labelSelector
	}
	nodes, err := c.clientset.CoreV1().Nodes().List(ctx, listOpts)
	if err != nil {
		return nil, fmt.Errorf("failed to list nodes: %w", err)
	}
	return nodes, nil
}

func (c *Client) Cordon(ctx context.Context, nodeName string) error {
	return retry.RetryOnConflict(retry.DefaultBackoff, func() error {
		node, err := c.clientset.CoreV1().Nodes().Get(ctx, nodeName, metav1.GetOptions{})
		if err != nil {
			return err
		}
		node.Spec.Unschedulable = true
		_, err = c.clientset.CoreV1().Nodes().Update(ctx, node, metav1.UpdateOptions{})
		return err
	})
}

func (c *Client) Uncordon(ctx context.Context, nodeName string) error {
	return retry.RetryOnConflict(retry.DefaultBackoff, func() error {
		node, err := c.clientset.CoreV1().Nodes().Get(ctx, nodeName, metav1.GetOptions{})
		if err != nil {
			return err
		}
		node.Spec.Unschedulable = false
		_, err = c.clientset.CoreV1().Nodes().Update(ctx, node, metav1.UpdateOptions{})
		return err
	})
}

func (c *Client) SetLabel(ctx context.Context, nodeName, key, value string) error {
	patch := map[string]interface{}{
		"metadata": map[string]interface{}{
			"labels": map[string]string{
				key: value,
			},
		},
	}
	patchBytes, _ := json.Marshal(patch)
	_, err := c.clientset.CoreV1().Nodes().Patch(ctx, nodeName, types.MergePatchType, patchBytes, metav1.PatchOptions{})
	return err
}

func (c *Client) SetAnnotation(ctx context.Context, nodeName, key, value string) error {
	patch := map[string]interface{}{
		"metadata": map[string]interface{}{
			"annotations": map[string]string{
				key: value,
			},
		},
	}
	patchBytes, _ := json.Marshal(patch)
	_, err := c.clientset.CoreV1().Nodes().Patch(ctx, nodeName, types.MergePatchType, patchBytes, metav1.PatchOptions{})
	return err
}

func (c *Client) AddTaint(ctx context.Context, nodeName, key string) error {
	return retry.RetryOnConflict(retry.DefaultBackoff, func() error {
		node, err := c.clientset.CoreV1().Nodes().Get(ctx, nodeName, metav1.GetOptions{})
		if err != nil {
			return err
		}
		for _, t := range node.Spec.Taints {
			if t.Key == key {
				return nil
			}
		}
		node.Spec.Taints = append(node.Spec.Taints, corev1.Taint{Key: key, Effect: corev1.TaintEffectNoSchedule})
		_, err = c.clientset.CoreV1().Nodes().Update(ctx, node, metav1.UpdateOptions{})
		return err
	})
}

func (c *Client) RemoveTaint(ctx context.Context, nodeName, key string) error {
	return retry.RetryOnConflict(retry.DefaultBackoff, func() error {
		node, err := c.clientset.CoreV1().Nodes().Get(ctx, nodeName, metav1.GetOptions{})
		if err != nil {
			return err
		}
		newTaints := make([]corev1.Taint, 0, len(node.Spec.Taints))
		for _, t := range node.Spec.Taints {
			if t.Key != key {
				newTaints = append(newTaints, t)
			}
		}
		if len(newTaints) == len(node.Spec.Taints) {
			return nil
		}
		node.Spec.Taints = newTaints
		_, err = c.clientset.CoreV1().Nodes().Update(ctx, node, metav1.UpdateOptions{})
		return err
	})
}

// GetNodeStartTime queries the K8s stats summary API for the node's actual boot time.
// This is the correct uptime source — it updates on VM reset, unlike metadata.creationTimestamp.
// Requires nodes/proxy RBAC permission.
func (c *Client) GetNodeStartTime(ctx context.Context, nodeName string) (time.Time, error) {
	resp, err := c.clientset.CoreV1().RESTClient().Get().
		Resource("nodes").
		Name(nodeName).
		SubResource("proxy").
		Suffix("stats/summary").
		Do(ctx).
		Raw()

	if err != nil {
		return time.Time{}, fmt.Errorf("failed to get stats summary for node %s: %w", nodeName, err)
	}

	var summary struct {
		Node struct {
			StartTime string `json:"startTime"`
		} `json:"node"`
	}

	if err := json.Unmarshal(resp, &summary); err != nil {
		return time.Time{}, fmt.Errorf("failed to parse stats summary for node %s: %w", nodeName, err)
	}

	startTime, err := time.Parse(time.RFC3339, summary.Node.StartTime)
	if err != nil {
		return time.Time{}, fmt.Errorf("failed to parse startTime %q for node %s: %w", summary.Node.StartTime, nodeName, err)
	}

	return startTime, nil
}

// IsNodeReady checks if a node has the Ready condition set to True.
func IsNodeReady(node *corev1.Node) bool {
	for _, cond := range node.Status.Conditions {
		if cond.Type == corev1.NodeReady && cond.Status == corev1.ConditionTrue {
			return true
		}
	}
	return false
}

func IsCordoned(node *corev1.Node) bool {
	return node.Spec.Unschedulable
}

func HasTaint(node *corev1.Node, key string) bool {
	for _, t := range node.Spec.Taints {
		if t.Key == key {
			return true
		}
	}
	return false
}
