package discovery

import (
	"context"
	"fmt"
	"regexp"
	"strings"

	corev1 "k8s.io/api/core/v1"

	"crusoe-node-remediation/internal/config"
	"crusoe-node-remediation/internal/constants"
	"crusoe-node-remediation/internal/k8s"
)

// NodeInfo holds metadata about a discovered node.
type NodeInfo struct {
	Name       string
	InstanceID string
	NodepoolID string
	Node       *corev1.Node
}

// NodeGroup is a set of nodes in the same nodepool.
type NodeGroup struct {
	NodepoolID string
	Nodes      []NodeInfo
}

// Discoverer finds target nodes via the K8s API.
type Discoverer struct {
	k8sClient *k8s.Client
	cfg       *config.Config
}

func NewDiscoverer(k8sClient *k8s.Client, cfg *config.Config) *Discoverer {
	return &Discoverer{k8sClient: k8sClient, cfg: cfg}
}

// Discover finds nodes matching the configured selectors and filters,
// grouped by nodepool.
func (d *Discoverer) Discover(ctx context.Context) ([]NodeGroup, error) {
	selectorParts := []string{}
	for k, v := range d.cfg.NodeSelector.MatchLabels {
		selectorParts = append(selectorParts, fmt.Sprintf("%s=%s", k, v))
	}
	labelSelector := strings.Join(selectorParts, ",")

	nodeList, err := d.k8sClient.ListNodes(ctx, labelSelector)
	if err != nil {
		return nil, fmt.Errorf("failed to list nodes: %w", err)
	}

	var typeRegex *regexp.Regexp
	if d.cfg.InstanceTypeFilter != "" {
		typeRegex, err = regexp.Compile(d.cfg.InstanceTypeFilter)
		if err != nil {
			return nil, fmt.Errorf("invalid instanceTypeFilter: %w", err)
		}
	}

	groupMap := make(map[string][]NodeInfo)

	for i := range nodeList.Items {
		node := &nodeList.Items[i]

		if typeRegex != nil {
			instanceType := node.Labels[constants.LabelInstanceType]
			if instanceType == "" || !typeRegex.MatchString(instanceType) {
				continue
			}
		}

		nodepoolID := node.Labels[constants.LabelNodepoolID]
		instanceID := node.Labels[constants.LabelInstanceID]

		info := NodeInfo{
			Name:       node.Name,
			InstanceID: instanceID,
			NodepoolID: nodepoolID,
			Node:       node,
		}

		groupMap[nodepoolID] = append(groupMap[nodepoolID], info)
	}

	groups := make([]NodeGroup, 0, len(groupMap))
	for poolID, nodes := range groupMap {
		groups = append(groups, NodeGroup{
			NodepoolID: poolID,
			Nodes:      nodes,
		})
	}

	return groups, nil
}
