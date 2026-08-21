package remediation

import (
	"context"
	"time"

	"crusoe-node-remediation/internal/constants"
	"crusoe-node-remediation/internal/discovery"
	"crusoe-node-remediation/internal/k8s"
)

// ExcludeReason explains why a node was excluded from remediation.
type ExcludeReason string

const (
	ExcludeNone            ExcludeReason = ""
	ExcludeSelfNode        ExcludeReason = "self-node"
	ExcludeUndetermined    ExcludeReason = "undetermined"
	ExcludeCooldown        ExcludeReason = "cooldown"
	ExcludeCordonedByOther ExcludeReason = "cordoned-by-others"
	ExcludeGuardrail       ExcludeReason = "guardrail"
)

// NodeStatus captures the full evaluated state of a single node during a run.
// Used by both the remediation decision logic in Run() and by aggregatePoolStatus()
// for report generation — ensuring no drift between what the manager sees and
// what the CRD reports.
type NodeStatus struct {
	Name             string
	InstanceID       string
	Ready            bool
	Phase            constants.Phase
	Managed          bool
	Uptime           time.Duration
	InCooldown       bool
	Excluded         bool
	ExcludeReason    ExcludeReason
	Action           ActionTier
	GuardrailBlocked bool
}

// evaluateNode inspects a node and returns its full status.
// This consolidates the scattered checks (self-node skip, uptime query,
// cooldown check, action classification) into one function used by both
// Run() for decision-making and aggregatePoolStatus() for reporting.
func (m *Manager) evaluateNode(ctx context.Context, nodeInfo discovery.NodeInfo, selfNode string) NodeStatus {
	status := NodeStatus{
		Name:       nodeInfo.Name,
		InstanceID: nodeInfo.InstanceID,
		Ready:      k8s.IsNodeReady(nodeInfo.Node),
		Phase:      constants.Phase(nodeInfo.Node.Labels[constants.LabelRemediationPhase]),
		Managed:    nodeInfo.Node.Labels[constants.LabelRemediationManaged] == "true",
	}

	// Check self-node exclusion
	if selfNode != "" && nodeInfo.Name == selfNode {
		status.Excluded = true
		status.ExcludeReason = ExcludeSelfNode
		return status
	}

	// Query uptime
	startTime, err := m.deps.UptimeEval.GetNodeStartTime(ctx, nodeInfo.Name)
	if err != nil {
		status.Excluded = true
		status.ExcludeReason = ExcludeUndetermined
		return status
	}
	status.Uptime = time.Since(startTime)

	// Check cooldown
	if m.isInRemediationCooldown(nodeInfo.Node) {
		status.InCooldown = true
		status.Excluded = true
		status.ExcludeReason = ExcludeCooldown
		return status
	}

	// Classify action based on uptime
	status.Action = ClassifyUptime(
		status.Uptime,
		time.Duration(m.deps.Config.CordonThreshold),
		time.Duration(m.deps.Config.RemediationThreshold),
	)

	return status
}
