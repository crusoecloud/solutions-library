package remediation

import (
	"context"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/tools/record"

	"crusoe-node-remediation/internal/actions"
	"crusoe-node-remediation/internal/config"
	"crusoe-node-remediation/internal/constants"
	"crusoe-node-remediation/internal/discovery"
	"crusoe-node-remediation/internal/guardrails"
	"crusoe-node-remediation/internal/k8s"
)

// UptimeEvaluator interface for querying VM uptime.
type UptimeEvaluator interface {
	GetNodeStartTime(ctx context.Context, nodeName string) (time.Time, error)
}

// formatUptime returns a human-readable uptime string (e.g. "2d5h", "3h20m", "15m").
func formatUptime(d time.Duration) string {
	d = d.Round(time.Second)
	days := int(d.Hours()) / 24
	hours := int(d.Hours()) % 24
	minutes := int(d.Minutes()) % 60
	seconds := int(d.Seconds()) % 60
	switch {
	case days > 0:
		return fmt.Sprintf("%dd%dh", days, hours)
	case hours > 0:
		return fmt.Sprintf("%dh%dm", hours, minutes)
	case minutes > 0:
		return fmt.Sprintf("%dm%ds", minutes, seconds)
	default:
		return fmt.Sprintf("%ds", seconds)
	}
}

// shortPoolID returns a shortened pool ID (first 8 chars) for logging.
func shortPoolID(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// boolToInt returns 1 for true, 0 for false.
func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// DrainManager interface for node draining.
type DrainManager interface {
	Drain(ctx context.Context, nodeName string) error
	ForceAfterEvictionFailure(ctx context.Context, nodeName string) error
}

// StepCreator interface for creating remediation steps.
type StepCreator interface {
	CreateFromConfig(cfg config.ActionConfig) (actions.Step, error)
}

// Dependencies holds all the components the manager needs.
type Dependencies struct {
	K8sClient    *k8s.Client
	DrainMgr     DrainManager
	StepFactory  StepCreator
	UptimeEval   UptimeEvaluator
	GuardChecker *guardrails.Checker
	Discoverer   *discovery.Discoverer
	Config       *config.Config
	Recorder     record.EventRecorder
	ReportWriter *ReportWriter // nil-safe — Run() checks for nil before calling WriteReport
}

// Manager orchestrates the node remediation.
type Manager struct {
	deps Dependencies
}

func NewManager(deps Dependencies) *Manager {
	return &Manager{deps: deps}
}

// Run executes one full remediation pass.
func (m *Manager) Run(ctx context.Context) (RunResult, error) {
	log.Println("starting remediation run")

	result := RunResult{
		LastRunTime:   time.Now().UTC(),
		LastRunStatus: "running",
		Config: ConfigSnapshot{
			CordonThreshold:      formatUptime(time.Duration(m.deps.Config.CordonThreshold)),
			RemediationThreshold: formatUptime(time.Duration(m.deps.Config.RemediationThreshold)),
			RemediationCooldown:  formatUptime(time.Duration(m.deps.Config.RemediationCooldown)),
			ActionType:           m.deps.Config.Action.Type,
			DryRun:               m.deps.Config.DryRun,
			GuardrailsGlobalMax:  m.deps.Config.Guardrails.GlobalMaxCordoned,
			GuardrailsPerPoolMax: m.deps.Config.Guardrails.PerPoolMaxCordoned,
		},
	}

	// Write initial "running" status to CRs (progressive update #1)
	if m.deps.ReportWriter != nil {
		if err := m.deps.ReportWriter.WriteReport(ctx, result); err != nil {
			log.Printf("warning: failed to write initial remediation report: %v", err)
		}
	}

	groups, err := m.deps.Discoverer.Discover(ctx)
	if err != nil {
		result.LastRunStatus = "failed"
		if m.deps.ReportWriter != nil {
			if err := m.deps.ReportWriter.WriteReport(ctx, result); err != nil {
				log.Printf("warning: failed to write remediation report: %v", err)
			}
		}
		return result, fmt.Errorf("node discovery failed: %w", err)
	}

	if len(groups) == 0 {
		log.Println("no target nodes found")
		result.LastRunStatus = "succeeded"
		// Write final status even for empty runs
		if m.deps.ReportWriter != nil {
			if err := m.deps.ReportWriter.WriteReport(ctx, result); err != nil {
				log.Printf("warning: failed to write remediation report: %v", err)
			}
		}
		return result, nil
	}

	// Count total nodes in cluster (for guardrail calculations)
	globalTotal := m.countTotalNodes(ctx)
	globalReady, globalNotReady, globalRemediating := m.countNodeStates(ctx)

	log.Printf("cluster: %d nodes (%d ready, %d notReady, %d remediating)",
		globalTotal, globalReady, globalNotReady, globalRemediating)
	log.Printf("discovered %d nodepools, %d targeted nodes",
		len(groups), m.totalNodeCount(groups))

	// Log node selector, instance type filter, and discovered nodepools
	selectorParts := []string{}
	if len(m.deps.Config.NodeSelector.MatchLabels) > 0 {
		for k, v := range m.deps.Config.NodeSelector.MatchLabels {
			selectorParts = append(selectorParts, k+"="+v)
		}
	}
	if m.deps.Config.InstanceTypeFilter != "" {
		selectorParts = append(selectorParts, constants.LabelInstanceType+"=~"+m.deps.Config.InstanceTypeFilter)
	}
	if len(selectorParts) > 0 {
		log.Printf("targeting: %s", strings.Join(selectorParts, ", "))
	}
	if len(groups) > 0 {
		var poolIDs []string
		for _, g := range groups {
			poolIDs = append(poolIDs, shortPoolID(g.NodepoolID))
		}
		log.Printf("nodepools: %s", strings.Join(poolIDs, ", "))
	}

	// Log global guardrail state
	globalMax, _ := m.deps.GuardChecker.MaxAllowed(globalTotal, 0)
	log.Printf("guardrails: %d remediating / %d max, action=%s, forceAfterEvictionFailure=%v, drainTimeout=%s",
		globalRemediating, globalMax, m.deps.Config.Action.Type, m.deps.Config.ForceAfterEvictionFailure, formatUptime(m.deps.Config.DrainTimeout))

	// Log guardrail config (shows how max was calculated)
	guardParts := []string{}
	if m.deps.Config.Guardrails.GlobalMaxCordoned > 0 {
		guardParts = append(guardParts, fmt.Sprintf("globalMax=%d", m.deps.Config.Guardrails.GlobalMaxCordoned))
	}
	if m.deps.Config.Guardrails.GlobalMaxCordonedPercent != nil {
		guardParts = append(guardParts, fmt.Sprintf("globalMaxPercent=%d%% (→%d of %d)", *m.deps.Config.Guardrails.GlobalMaxCordonedPercent, (*m.deps.Config.Guardrails.GlobalMaxCordonedPercent*globalTotal)/100, globalTotal))
	}
	if m.deps.Config.Guardrails.PerPoolMaxCordoned > 0 {
		guardParts = append(guardParts, fmt.Sprintf("perPoolMax=%d", m.deps.Config.Guardrails.PerPoolMaxCordoned))
	}
	if m.deps.Config.Guardrails.PerPoolMaxCordonedPercent != nil {
		guardParts = append(guardParts, fmt.Sprintf("perPoolMaxPercent=%d%%", *m.deps.Config.Guardrails.PerPoolMaxCordonedPercent))
	}
	if len(guardParts) > 0 {
		log.Printf("guardrail config: %s", strings.Join(guardParts, ", "))
	}

	var failedCount int
	var failedNodes []string

	for _, group := range groups {
		poolRemediating := m.countActiveNodesInPool(ctx, group.NodepoolID)
		poolTotal := len(group.Nodes)

		// Get the node this pod is running on — never drain it
		selfNode := os.Getenv("NODE_NAME")
		selfNodeSkipped := false

		// Evaluate all nodes in this pool using evaluateNode()
		var nodeStatuses []NodeStatus
		type nodeWithUptime struct {
			info   discovery.NodeInfo
			uptime time.Duration
		}
		var nodesWithUptime []nodeWithUptime
		var remediationCooldownCount, failedUptimeCount int

		for _, nodeInfo := range group.Nodes {
			status := m.evaluateNode(ctx, nodeInfo, selfNode)
			nodeStatuses = append(nodeStatuses, status)

			if status.Excluded {
				switch status.ExcludeReason {
				case ExcludeSelfNode:
					log.Printf("skipping node %s: running this pod, excluded from remediation", nodeInfo.Name)
					selfNodeSkipped = true
				case ExcludeUndetermined:
					log.Printf("skipping node %s: failed to get uptime", nodeInfo.Name)
					failedUptimeCount++
				case ExcludeCooldown:
					log.Printf("skipping node %s: in remediationCooldown (remediated within %s)", nodeInfo.Name, formatUptime(time.Duration(m.deps.Config.RemediationCooldown)))
					remediationCooldownCount++
				}
				continue
			}

			nodesWithUptime = append(nodesWithUptime, nodeWithUptime{info: nodeInfo, uptime: status.Uptime})
		}

		// Sort nodes by configured prioritizer (default: highest uptime first)
		nodesForSort := make([]NodeWithUptime, len(nodesWithUptime))
		for i, nwu := range nodesWithUptime {
			nodesForSort[i] = NodeWithUptime{
				Name:       nwu.info.Name,
				InstanceID: nwu.info.InstanceID,
				Uptime:     nwu.uptime,
			}
		}
		prioritizer, err := GetPrioritizer(m.deps.Config.NodePriority)
		if err != nil {
			log.Printf("warning: invalid nodePriority %q, using highest-uptime: %v", m.deps.Config.NodePriority, err)
			prioritizer = highestUptime{}
		}
		prioritizer.Sort(nodesForSort)

		// poolTotal includes all nodes (including self-node) for accurate counts.
		// Guardrail calculations use poolTotal as-is — the self-node is counted
		// in the total but will never be remediated, so it effectively reduces
		// the available slots by being a non-remediable node.
		poolReady := poolTotal - poolRemediating
		_, poolMax := m.deps.GuardChecker.MaxAllowed(globalTotal, poolTotal)

		excludedNode := "none"
		if selfNodeSkipped {
			excludedNode = selfNode
		}
		log.Printf("pool %s: %d nodes (%d ready, %d remediating / %d max, cooldown=%d, unreachable=%d, excluded=%s)",
			shortPoolID(group.NodepoolID), poolTotal, poolReady, poolRemediating, poolMax, remediationCooldownCount, failedUptimeCount, excludedNode)
		// Note: failedUptimeCount is the count of undetermined nodes (failed uptime query)

		// Build a lookup from sorted names back to original nodeWithUptime
		lookup := make(map[string]nodeWithUptime, len(nodesWithUptime))
		for _, nwu := range nodesWithUptime {
			lookup[nwu.info.Name] = nwu
		}

		for _, nfs := range nodesForSort {
			nwu := lookup[nfs.Name]
			action := ClassifyUptime(nwu.uptime, time.Duration(m.deps.Config.CordonThreshold), time.Duration(m.deps.Config.RemediationThreshold))

			switch action {
			case ActionNone:
				m.handleMonitoredNode(ctx, nwu.info)
			case ActionCordon:
				m.handleCordonNode(ctx, nwu.info, nwu.uptime, &globalRemediating, &poolRemediating, globalTotal, poolTotal)
			case ActionRemediate:
				if err := m.handleRemediateNode(ctx, nwu.info, nwu.uptime, &globalRemediating, &poolRemediating, globalTotal, poolTotal); err != nil {
					failedCount++
					failedNodes = append(failedNodes, nwu.info.Name+": "+err.Error())
				}
			}
		}

		// Aggregate pool report and write progressive update
		poolReport := aggregatePoolStatus(shortPoolID(group.NodepoolID), poolTotal, nodeStatuses)
		result.PoolReports = append(result.PoolReports, poolReport)

		// Progressive update: write CR after each pool is processed
		if m.deps.ReportWriter != nil {
			if err := m.deps.ReportWriter.WriteReport(ctx, result); err != nil {
				log.Printf("warning: failed to write progressive remediation report: %v", err)
			}
		}
	}

	log.Println("remediation run complete")

	// Summary: list cordoned nodes waiting for remediation threshold
	cordonedPending := []string{}
	for _, group := range groups {
		for _, nodeInfo := range group.Nodes {
			if nodeInfo.Node.Labels[constants.LabelRemediationPhase] == string(constants.PhaseCordoned) {
				cordonedPending = append(cordonedPending, nodeInfo.Name)
			}
		}
	}
	if len(cordonedPending) > 0 {
		log.Printf("cordoned pending remediation: %d node(s) waiting for remediationThreshold %s — %s",
			len(cordonedPending), formatUptime(time.Duration(m.deps.Config.RemediationThreshold)), strings.Join(cordonedPending, ", "))
	}

	result.ClusterTotal = globalTotal
	if failedCount > 0 {
		result.LastRunStatus = "failed"
		result.Failures = buildFailures(failedNodes)
		// Write final failed status to CRs
		if m.deps.ReportWriter != nil {
			if err := m.deps.ReportWriter.WriteReport(ctx, result); err != nil {
				log.Printf("warning: failed to write final remediation report: %v", err)
			}
		}
		return result, fmt.Errorf("%d nodes failed remediation: %s", failedCount, strings.Join(failedNodes, "; "))
	}
	result.LastRunStatus = "succeeded"
	// Write final succeeded status to CRs
	if m.deps.ReportWriter != nil {
		if err := m.deps.ReportWriter.WriteReport(ctx, result); err != nil {
			log.Printf("warning: failed to write final remediation report: %v", err)
		}
	}
	return result, nil
}

// buildFailures converts a list of "node: error" strings into NodeFailure structs.
func buildFailures(failedNodes []string) []NodeFailure {
	var failures []NodeFailure
	for _, f := range failedNodes {
		parts := strings.SplitN(f, ": ", 2)
		node := parts[0]
		errMsg := ""
		if len(parts) > 1 {
			errMsg = parts[1]
		}
		failures = append(failures, NodeFailure{Node: node, Error: errMsg})
	}
	return failures
}

func (m *Manager) isInRemediationCooldown(node *corev1.Node) bool {
	completedAt := node.Annotations[constants.AnnotationActionCompletedAt]
	if completedAt == "" {
		return false
	}
	t, err := time.Parse(time.RFC3339, completedAt)
	if err != nil {
		return false
	}
	remediationCooldownDuration := time.Duration(m.deps.Config.RemediationCooldown)
	return time.Since(t) < remediationCooldownDuration
}

func (m *Manager) handleMonitoredNode(ctx context.Context, nodeInfo discovery.NodeInfo) {
	node := nodeInfo.Node

	if node.Labels[constants.LabelRemediationManaged] != "true" {
		return
	}
	if !k8s.IsCordoned(node) {
		return
	}

	if m.deps.Config.DryRun {
		log.Printf("[dry-run] would uncordon node %s (uptime below cordon threshold)", nodeInfo.Name)
		return
	}

	log.Printf("uncordoning node %s (uptime below threshold)", nodeInfo.Name)
	if err := m.deps.K8sClient.Uncordon(ctx, nodeInfo.Name); err != nil {
		log.Printf("ERROR: failed to uncordon node %s: %v", nodeInfo.Name, err)
		m.deps.Recorder.Eventf(nodeInfo.Node, corev1.EventTypeWarning, "UncordonFailed", "failed to uncordon: %v", err)
		return
	}
	m.deps.K8sClient.SetLabel(ctx, nodeInfo.Name, constants.LabelRemediationPhase, string(constants.PhaseMonitored))
	m.deps.K8sClient.RemoveTaint(ctx, nodeInfo.Name, constants.TaintScheduled)
	m.deps.K8sClient.RemoveTaint(ctx, nodeInfo.Name, constants.TaintDraining)
	m.deps.K8sClient.RemoveTaint(ctx, nodeInfo.Name, constants.TaintMaintenance)
	m.deps.K8sClient.SetAnnotation(ctx, nodeInfo.Name, constants.AnnotationUncordonedAt, time.Now().UTC().Format(time.RFC3339))
	m.deps.Recorder.Eventf(nodeInfo.Node, corev1.EventTypeNormal, "NodeUncordoned", "node uncordoned (uptime below threshold)")
	log.Printf("node %s uncordoned (uptime below threshold)", nodeInfo.Name)
}

func (m *Manager) handleCordonNode(ctx context.Context, nodeInfo discovery.NodeInfo, uptime time.Duration, globalActive, poolActive *int, globalTotal, poolTotal int) {
	// Guardrail: skip nodes cordoned by someone else. If the node is
	// cordoned (Spec.Unschedulable=true) but NOT managed by us (no
	// LabelRemediationManaged), an engineer cordoned it for manual
	// maintenance — don't adopt it.
	if k8s.IsCordoned(nodeInfo.Node) && nodeInfo.Node.Labels[constants.LabelRemediationManaged] != "true" {
		namespace := os.Getenv("POD_NAMESPACE")
		if namespace == "" {
			namespace = "crusoe-node-remediation"
		}
		log.Printf("skipping node %s: already cordoned (not managed by %s)", nodeInfo.Name, namespace)
		return
	}

	if !m.deps.GuardChecker.CanCordon(*globalActive, *poolActive, globalTotal, poolTotal) {
		gMax, pMax := m.deps.GuardChecker.MaxAllowed(globalTotal, poolTotal)
		log.Printf("skipping node %s: guardrail exceeded (remediating=%d/%d global, %d/%d pool)",
			nodeInfo.Name, *globalActive, gMax, *poolActive, pMax)
		return
	}

	if m.deps.Config.DryRun {
		log.Printf("[dry-run] would cordon node %s (uptime %s)", nodeInfo.Name, formatUptime(uptime))
		return
	}

	log.Printf("cordoning node %s (uptime %s)", nodeInfo.Name, formatUptime(uptime))

	m.deps.K8sClient.SetLabel(ctx, nodeInfo.Name, constants.LabelRemediationManaged, "true")

	if err := m.deps.K8sClient.Cordon(ctx, nodeInfo.Name); err != nil {
		log.Printf("ERROR: failed to cordon node %s: %v", nodeInfo.Name, err)
		return
	}

	m.deps.K8sClient.SetLabel(ctx, nodeInfo.Name, constants.LabelRemediationPhase, string(constants.PhaseCordoned))
	m.deps.K8sClient.AddTaint(ctx, nodeInfo.Name, constants.TaintScheduled)

	now := time.Now().UTC().Format(time.RFC3339)
	m.deps.K8sClient.SetAnnotation(ctx, nodeInfo.Name, constants.AnnotationCordonedAt, now)
	m.deps.K8sClient.SetAnnotation(ctx, nodeInfo.Name, constants.AnnotationCordonUptime, fmt.Sprintf("%v", uptime))
	m.deps.K8sClient.SetAnnotation(ctx, nodeInfo.Name, constants.AnnotationManagedBy, constants.ManagedByValue)
	m.deps.K8sClient.SetAnnotation(ctx, nodeInfo.Name, constants.AnnotationLastAction, "cordon")
	m.deps.Recorder.Eventf(nodeInfo.Node, corev1.EventTypeNormal, "NodeCordoned", "node cordoned at %v uptime", uptime)
	log.Printf("node %s cordoned (uptime %s)", nodeInfo.Name, formatUptime(uptime))

	// Log why this node was only cordoned, not remediated — helps humans
	// understand the two-phase design and that the node will be picked up
	// for remediation on a future run once uptime crosses remediationThreshold.
	remaining := time.Duration(m.deps.Config.RemediationThreshold) - uptime
	if remaining > 0 {
		log.Printf("node %s cordoned but not remediated: uptime %s is below remediationThreshold %s (will remediate in ~%s)",
			nodeInfo.Name, formatUptime(uptime), formatUptime(time.Duration(m.deps.Config.RemediationThreshold)), formatUptime(remaining))
	}

	// Only increment for newly cordoned nodes. If the node was already in
	// PhaseCordoned (cordoned by us in a previous run), it already holds a
	// guardrail slot from countActiveNodesInPool — don't double-count.
	if nodeInfo.Node.Labels[constants.LabelRemediationPhase] != string(constants.PhaseCordoned) {
		*globalActive++
		*poolActive++
	}
}

func (m *Manager) handleRemediateNode(ctx context.Context, nodeInfo discovery.NodeInfo, uptime time.Duration, globalActive, poolActive *int, globalTotal, poolTotal int) error {
	// Guardrail: skip nodes cordoned by someone else. If the node is
	// cordoned (Spec.Unschedulable=true) but NOT managed by us (no
	// LabelRemediationManaged), an engineer cordoned it for manual
	// maintenance — don't drain, reset, or uncordon it.
	if k8s.IsCordoned(nodeInfo.Node) && nodeInfo.Node.Labels[constants.LabelRemediationManaged] != "true" {
		namespace := os.Getenv("POD_NAMESPACE")
		if namespace == "" {
			namespace = "crusoe-node-remediation"
		}
		log.Printf("skipping node %s: already cordoned (not managed by %s)", nodeInfo.Name, namespace)
		return nil
	}

	// If the node is already in an active remediation phase, it was being
	// remediated by a previous run that didn't complete. Skip the guardrail
	// check — the node already holds a slot, so retrying it doesn't exceed
	// the limit. Without this, stuck nodes deadlock: they count toward the
	// guardrail but can never be retried, blocking all other nodes too.
	currentPhase := constants.Phase(nodeInfo.Node.Labels[constants.LabelRemediationPhase])
	isRetry := currentPhase.IsActive()

	if !isRetry && !m.deps.GuardChecker.CanCordon(*globalActive, *poolActive, globalTotal, poolTotal) {
		gMax, pMax := m.deps.GuardChecker.MaxAllowed(globalTotal, poolTotal)
		log.Printf("skipping node %s: guardrail exceeded (remediating=%d/%d global, %d/%d pool)",
			nodeInfo.Name, *globalActive, gMax, *poolActive, pMax)
		return nil
	}

	if m.deps.Config.DryRun {
		log.Printf("[dry-run] would remediate node %s with action %s (uptime %s)",
			nodeInfo.Name, m.deps.Config.Action.Type, formatUptime(uptime))
		return nil
	}

	log.Printf("remediating node %s with action %s (uptime %s)",
		nodeInfo.Name, m.deps.Config.Action.Type, formatUptime(uptime))

	// Check cross-run retry limit via attempt annotation
	attempt := getAttemptAnnotation(nodeInfo.Node)
	if attempt >= m.deps.Config.Action.MaxRetries {
		log.Printf("node %s exceeded max retries (%d/%d), leaving cordoned — manual intervention required",
			nodeInfo.Name, attempt, m.deps.Config.Action.MaxRetries)
		m.deps.Recorder.Eventf(nodeInfo.Node, corev1.EventTypeWarning, "MaxRetriesExceeded",
			"remediation failed after %d attempts, manual intervention required", attempt)
		log.Printf("node %s max retries exceeded (%d/%d), manual intervention required", nodeInfo.Name, attempt, m.deps.Config.Action.MaxRetries)
		return fmt.Errorf("node %s exceeded max retries (%d/%d)", nodeInfo.Name, attempt, m.deps.Config.Action.MaxRetries)
	}
	m.deps.K8sClient.SetAnnotation(ctx, nodeInfo.Name, constants.AnnotationAttempt, strconv.Itoa(attempt+1))

	// Set managed label
	m.deps.K8sClient.SetLabel(ctx, nodeInfo.Name, constants.LabelRemediationManaged, "true")

	// 1. Cordon — skip if already cordoned (idempotent: verify actual state)
	alreadyCordoned := k8s.IsCordoned(nodeInfo.Node)
	if !alreadyCordoned {
		log.Printf("node %s: phase=cordon starting", nodeInfo.Name)
		if err := m.deps.K8sClient.Cordon(ctx, nodeInfo.Name); err != nil {
			log.Printf("ERROR: failed to cordon node %s: %v", nodeInfo.Name, err)
			return err
		}
		m.deps.K8sClient.SetLabel(ctx, nodeInfo.Name, constants.LabelRemediationPhase, string(constants.PhaseCordoned))
		m.deps.K8sClient.AddTaint(ctx, nodeInfo.Name, constants.TaintScheduled)
		m.deps.K8sClient.SetAnnotation(ctx, nodeInfo.Name, constants.AnnotationCordonedAt, time.Now().UTC().Format(time.RFC3339))
		m.deps.Recorder.Eventf(nodeInfo.Node, corev1.EventTypeNormal, "NodeCordoned", "node cordoned for remediation")
		log.Printf("node %s: phase=cordon done", nodeInfo.Name)
	} else {
		log.Printf("node %s: phase=cordon skipped (already cordoned)", nodeInfo.Name)
	}

	// Increment guardrail counters — this node is now being remediated.
	// Only increment for new remediations, not retries (the node already
	// holds a guardrail slot from the previous run).
	if !isRetry {
		*globalActive++
		*poolActive++
	}

	// 2. Drain — always call. Drain is idempotent: if pods are already
	// evicted (from a previous run), it succeeds immediately.
	log.Printf("node %s: phase=drain starting (timeout=%s)", nodeInfo.Name, formatUptime(time.Duration(m.deps.Config.DrainTimeout)))
	m.deps.K8sClient.SetLabel(ctx, nodeInfo.Name, constants.LabelRemediationPhase, string(constants.PhaseDraining))
	m.deps.K8sClient.AddTaint(ctx, nodeInfo.Name, constants.TaintDraining)
	m.deps.K8sClient.RemoveTaint(ctx, nodeInfo.Name, constants.TaintScheduled)
	m.deps.K8sClient.SetAnnotation(ctx, nodeInfo.Name, constants.AnnotationDrainStartedAt, time.Now().UTC().Format(time.RFC3339))

	drainStart := time.Now()
	drainErr := m.deps.DrainMgr.Drain(ctx, nodeInfo.Name)
	drainElapsed := time.Since(drainStart).Round(time.Second)
	if drainErr != nil {
		log.Printf("node %s: phase=drain blocked after %s: %v", nodeInfo.Name, drainElapsed, drainErr)
		m.deps.Recorder.Eventf(nodeInfo.Node, corev1.EventTypeWarning, "DrainBlocked", "drain blocked: %v", drainErr)
		if m.deps.Config.ForceAfterEvictionFailure {
			log.Printf("node %s: phase=force-drain starting", nodeInfo.Name)
			m.deps.K8sClient.SetLabel(ctx, nodeInfo.Name, constants.LabelRemediationPhase, string(constants.PhaseForceDraining))
			m.deps.K8sClient.SetAnnotation(ctx, nodeInfo.Name, constants.AnnotationForceDrainStartedAt, time.Now().UTC().Format(time.RFC3339))
			if err := m.deps.DrainMgr.ForceAfterEvictionFailure(ctx, nodeInfo.Name); err != nil {
				log.Printf("ERROR: force drain failed for node %s: %v", nodeInfo.Name, err)
				m.deps.Recorder.Eventf(nodeInfo.Node, corev1.EventTypeWarning, "ForceDrainFailed", "force drain failed: %v", err)
				return err
			}
			m.deps.Recorder.Eventf(nodeInfo.Node, corev1.EventTypeNormal, "NodeDrained", "node force-drained after graceful drain blocked")
			log.Printf("node %s: phase=force-drain done", nodeInfo.Name)
		} else {
			log.Printf("node %s: phase=drain skipped (blocked, force disabled)", nodeInfo.Name)
			return drainErr
		}
	} else {
		m.deps.Recorder.Eventf(nodeInfo.Node, corev1.EventTypeNormal, "NodeDrained", "node drained in %s", drainElapsed)
		log.Printf("node %s: phase=drain done in %s", nodeInfo.Name, drainElapsed)
	}

	// 3. Execute remediation step(s)
	log.Printf("node %s: phase=action starting (type=%s)", nodeInfo.Name, m.deps.Config.Action.Type)
	m.deps.K8sClient.SetLabel(ctx, nodeInfo.Name, constants.LabelRemediationPhase, string(constants.PhaseActionRunning))
	m.deps.K8sClient.AddTaint(ctx, nodeInfo.Name, constants.TaintMaintenance)
	m.deps.K8sClient.RemoveTaint(ctx, nodeInfo.Name, constants.TaintDraining)
	m.deps.K8sClient.SetAnnotation(ctx, nodeInfo.Name, constants.AnnotationActionTriggeredAt, time.Now().UTC().Format(time.RFC3339))
	m.deps.K8sClient.SetAnnotation(ctx, nodeInfo.Name, constants.AnnotationActionType, m.deps.Config.Action.Type)

	// Build step from config
	step, err := m.deps.StepFactory.CreateFromConfig(m.deps.Config.Action)
	if err != nil {
		log.Printf("ERROR: failed to create step for node %s: %v", nodeInfo.Name, err)
		m.deps.Recorder.Eventf(nodeInfo.Node, corev1.EventTypeWarning, "StepCreationFailed", "failed to create step: %v", err)
		return err
	}

	actNode := actions.NodeInfo{
		Name:       nodeInfo.Name,
		InstanceID: nodeInfo.InstanceID,
	}

	actionStart := time.Now()
	if err := step.Run(ctx, actNode, m.deps.Config.Action.Params); err != nil {
		log.Printf("node %s: phase=action failed after %s: step %s: %v", nodeInfo.Name, time.Since(actionStart).Round(time.Second), step.Type(), err)
		m.deps.Recorder.Eventf(nodeInfo.Node, corev1.EventTypeWarning, "StepFailed",
			"step %s failed (attempt %d): %v", step.Type(), attempt+1, err)
		// Leave node cordoned + tainted, next CronJob run will retry
		return err
	}
	log.Printf("node %s: phase=action done in %s (step=%s)", nodeInfo.Name, time.Since(actionStart).Round(time.Second), step.Type())

	// 4. Uncordon (skip for vm-delete — old node is gone)
	// Determine if the last action is vm-delete (single or multi-step)
	isDeleteAction := false
	if len(m.deps.Config.Action.Steps) > 0 {
		lastStep := m.deps.Config.Action.Steps[len(m.deps.Config.Action.Steps)-1]
		isDeleteAction = lastStep.Type == "vm-delete"
	} else if m.deps.Config.Action.Type == "vm-delete" {
		isDeleteAction = true
	}

	if isDeleteAction {
		log.Printf("node %s: phase=uncordon skipped (vm-delete, node replaced by CMK)", nodeInfo.Name)
	} else {
		log.Printf("node %s: phase=uncordon starting", nodeInfo.Name)
		if err := m.uncordonNode(ctx, nodeInfo, step.Type(), uptime); err != nil {
			// Uncordon failed — don't set action-completed-at, so remediationCooldown
			// won't skip this node on the next run
			return err
		}
	}

	// Set action-completed-at ONLY after successful uncordon (or vm-delete)
	m.deps.K8sClient.SetAnnotation(ctx, nodeInfo.Name, constants.AnnotationActionCompletedAt, time.Now().UTC().Format(time.RFC3339))

	return nil
}

func (m *Manager) uncordonNode(ctx context.Context, nodeInfo discovery.NodeInfo, stepType string, uptime time.Duration) error {
	m.deps.K8sClient.SetLabel(ctx, nodeInfo.Name, constants.LabelRemediationPhase, string(constants.PhaseUncordoning))
	if err := m.deps.K8sClient.Uncordon(ctx, nodeInfo.Name); err != nil {
		log.Printf("ERROR: failed to uncordon node %s: %v", nodeInfo.Name, err)
		return err
	}
	m.deps.K8sClient.RemoveTaint(ctx, nodeInfo.Name, constants.TaintMaintenance)
	m.deps.K8sClient.RemoveTaint(ctx, nodeInfo.Name, constants.TaintScheduled)
	m.deps.K8sClient.SetLabel(ctx, nodeInfo.Name, constants.LabelRemediationPhase, string(constants.PhaseMonitored))
	m.deps.K8sClient.SetAnnotation(ctx, nodeInfo.Name, constants.AnnotationUncordonedAt, time.Now().UTC().Format(time.RFC3339))
	m.deps.K8sClient.SetAnnotation(ctx, nodeInfo.Name, constants.AnnotationLastAction, fmt.Sprintf("%s-complete", stepType))
	m.deps.K8sClient.SetAnnotation(ctx, nodeInfo.Name, constants.AnnotationAttempt, "0")

	m.deps.Recorder.Eventf(nodeInfo.Node, corev1.EventTypeNormal, "NodeRemediated",
		"node remediated with %s after %s uptime", stepType, formatUptime(uptime))
	log.Printf("node %s: phase=uncordon done — remediation complete (step=%s)", nodeInfo.Name, stepType)
	return nil
}

func getAttemptAnnotation(node *corev1.Node) int {
	val := node.Annotations[constants.AnnotationAttempt]
	if val == "" {
		return 0
	}
	n, err := strconv.Atoi(val)
	if err != nil {
		return 0
	}
	return n
}

func (m *Manager) countActiveNodes(ctx context.Context) int {
	activePhases := fmt.Sprintf("%s in (%s,%s,%s,%s,%s)",
		constants.LabelRemediationPhase,
		constants.PhaseCordoned, constants.PhaseDraining, constants.PhaseForceDraining,
		constants.PhaseActionRunning, constants.PhaseUncordoning)

	nodes, err := m.deps.K8sClient.ListNodes(ctx, activePhases)
	if err != nil {
		log.Printf("warning: failed to count active nodes: %v", err)
		return 0
	}
	return len(nodes.Items)
}

func (m *Manager) countActiveNodesInPool(ctx context.Context, poolID string) int {
	selector := fmt.Sprintf("%s=%s,%s in (%s,%s,%s,%s,%s)",
		constants.LabelNodepoolID, poolID,
		constants.LabelRemediationPhase,
		constants.PhaseCordoned, constants.PhaseDraining, constants.PhaseForceDraining,
		constants.PhaseActionRunning, constants.PhaseUncordoning)

	nodes, err := m.deps.K8sClient.ListNodes(ctx, selector)
	if err != nil {
		log.Printf("warning: failed to count active nodes in pool %s: %v", poolID, err)
		return 0
	}
	return len(nodes.Items)
}

func (m *Manager) countTotalNodes(ctx context.Context) int {
	nodes, err := m.deps.K8sClient.ListNodes(ctx, "")
	if err != nil {
		log.Printf("warning: failed to count total nodes: %v", err)
		return 0
	}
	return len(nodes.Items)
}

// countNodeStates returns (ready, notReady, remediating) counts for the cluster.
func (m *Manager) countNodeStates(ctx context.Context) (ready, notReady, remediating int) {
	nodes, err := m.deps.K8sClient.ListNodes(ctx, "")
	if err != nil {
		log.Printf("warning: failed to count node states: %v", err)
		return 0, 0, 0
	}

	remediationPhases := map[string]bool{
		string(constants.PhaseCordoned):      true,
		string(constants.PhaseDraining):      true,
		string(constants.PhaseForceDraining): true,
		string(constants.PhaseActionRunning): true,
		string(constants.PhaseUncordoning):   true,
	}

	for _, node := range nodes.Items {
		if k8s.IsNodeReady(&node) {
			ready++
		} else {
			notReady++
		}
		if node.Labels[constants.LabelRemediationPhase] != "" &&
			remediationPhases[node.Labels[constants.LabelRemediationPhase]] {
			remediating++
		}
	}
	return ready, notReady, remediating
}

func (m *Manager) totalNodeCount(groups []discovery.NodeGroup) int {
	total := 0
	for _, g := range groups {
		total += len(g.Nodes)
	}
	return total
}
