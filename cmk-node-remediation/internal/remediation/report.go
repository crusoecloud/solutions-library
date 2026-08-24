package remediation

import (
	"context"
	"fmt"
	"time"

	"crusoe-node-remediation/internal/constants"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
)

// NodeFailure records a node that failed remediation during this run.
type NodeFailure struct {
	Node     string `json:"node"`
	Error    string `json:"error"`
	Attempts int    `json:"attempts"`
}

// PoolReport holds per-nodepool status for a single remediation run.
type PoolReport struct {
	NodepoolID         string `json:"nodepoolId"`
	TotalNodes         int    `json:"totalNodes"`
	ManagedNodes       int    `json:"managedNodes"`
	ReadyNodes         int    `json:"readyNodes"`
	NotReadyNodes      int    `json:"notReadyNodes"`
	RemediatingNodes   int    `json:"remediatingNodes"`
	PendingRemediation int    `json:"pendingRemediation"`
	CooldownNodes      int    `json:"cooldownNodes"`
	MonitoredNodes     int    `json:"monitoredNodes"`
	UnmanagedNodes     int    `json:"unmanagedNodes"`
	UndeterminedNodes  int    `json:"undeterminedNodes"`
	OkNodes            int    `json:"okNodes"`
	DueNodes           int    `json:"dueNodes"`
	ExcludedNode       string `json:"excludedNode"`
	GuardrailBlocked   int    `json:"guardrailBlocked"`
}

// ConfigSnapshot is a snapshot of the config used for a run.
type ConfigSnapshot struct {
	CordonThreshold      string `json:"cordonThreshold"`
	RemediationThreshold string `json:"remediationThreshold"`
	RemediationCooldown  string `json:"remediationCooldown"`
	ActionType           string `json:"actionType"`
	DryRun               bool   `json:"dryRun"`
	GuardrailsGlobalMax  int    `json:"guardrailsGlobalMax"`
	GuardrailsPerPoolMax int    `json:"guardrailsPerPoolMax"`
}

// RunResult captures the outcome of a single remediation pass.
type RunResult struct {
	LastRunTime   time.Time
	LastRunStatus string // "running" | "succeeded" | "failed"
	ClusterTotal  int    // all nodes in cluster
	Config        ConfigSnapshot
	PoolReports   []PoolReport
	Failures      []NodeFailure
}

// aggregatePoolStatus summarizes a list of NodeStatus into a PoolReport.
// This is the shared code path — both Run() and the CRD report use the
// same NodeStatus evaluation, so the report can never drift from what
// the manager actually saw.
func aggregatePoolStatus(poolID string, totalNodes int, statuses []NodeStatus) PoolReport {
	report := PoolReport{
		NodepoolID:   poolID,
		TotalNodes:   totalNodes,
		ExcludedNode: "none",
	}

	for _, s := range statuses {
		// Count ready/not-ready from actual node conditions (not subtraction)
		if s.Ready {
			report.ReadyNodes++
		} else {
			report.NotReadyNodes++
		}

		// Count active remediation phases
		if s.Phase.IsActive() {
			report.RemediatingNodes++
		}

		// Count cordoned-pending (cordoned but not yet being remediated)
		if s.Phase == constants.PhaseCordoned {
			report.PendingRemediation++
		}

		// Count cooldown
		if s.InCooldown {
			report.CooldownNodes++
		}

		// Count undetermined (failed uptime query)
		if s.ExcludeReason == ExcludeUndetermined {
			report.UndeterminedNodes++
		}

		// Track self-node exclusion
		if s.ExcludeReason == ExcludeSelfNode {
			report.ExcludedNode = s.Name
		}

		// Count guardrail-blocked
		if s.GuardrailBlocked {
			report.GuardrailBlocked++
		}

		// Count monitored: not in active remediation, not in cooldown,
		// not unreachable. The self-node IS counted as monitored — it's
		// healthy and being watched, just not a remediation target this run.
		// Unmanaged nodes (managed=false) are NOT counted as monitored.
		if !s.InCooldown && s.ExcludeReason != ExcludeUndetermined && !s.Phase.IsActive() && s.Managed {
			report.MonitoredNodes++
		}

		// Count managed nodes (have crusoe.ai/remediation.managed=true label)
		if s.Managed {
			report.ManagedNodes++
		}

		// Count unmanaged nodes (managed=false — permanently excluded by operator)
		if !s.Managed {
			report.UnmanagedNodes++
		}

		// Count OK vs DUE based on uptime threshold.
		// OK = below cordonThreshold (ActionNone) — nothing will happen.
		// DUE = at or above cordonThreshold (ActionCordon/ActionRemediate) — action needed.
		// Only count nodes not already in a column: excludes active remediation,
		// cooldown, unreachable, and unmanaged. Self-node IS counted (it has
		// an uptime and will eventually be remediated by a different pod).
		if !s.Phase.IsActive() && !s.InCooldown && s.ExcludeReason != ExcludeUndetermined && s.Managed {
			if s.Action == ActionNone {
				report.OkNodes++
			} else {
				report.DueNodes++
			}
		}
	}

	return report
}

// reportGVR is the GroupVersionResource for the RemediationReport CRD.
var reportGVR = schema.GroupVersionResource{
	Group:    "remediation.crusoe.ai",
	Version:  "v1alpha1",
	Resource: "remediationreports",
}

// ReportWriter creates and updates RemediationReport custom resources via the
// Kubernetes dynamic client. One CR is written per nodepool in the RunResult.
type ReportWriter struct {
	client    dynamic.Interface
	namespace string
}

// NewReportWriter returns a ReportWriter that writes RemediationReport CRs into
// the given namespace using the supplied dynamic client.
func NewReportWriter(client dynamic.Interface, namespace string) *ReportWriter {
	return &ReportWriter{client: client, namespace: namespace}
}

// WriteReport writes one RemediationReport CR per nodepool in result. If a CR
// already exists for a nodepool it is updated; otherwise it is created.
func (w *ReportWriter) WriteReport(ctx context.Context, result RunResult) error {
	for _, pool := range result.PoolReports {
		if err := w.writePoolReport(ctx, pool, result); err != nil {
			return fmt.Errorf("failed to write report for pool %s: %w", pool.NodepoolID, err)
		}
	}
	return nil
}

func (w *ReportWriter) writePoolReport(ctx context.Context, pool PoolReport, result RunResult) error {
	// Use the node pool name (np-<first8>) as the CR name — matches the
	// node naming pattern (e.g. np-0fe3d21c-1.us-southcentral1-a...).
	// Nodepool IDs are UUIDs; first 8 chars are practically unique within
	// a single cluster.
	name := pool.NodepoolID
	if len(name) > 8 {
		name = name[:8]
	}
	name = "np-" + name

	// Convert Go structs to JSON-compatible maps. The dynamic client (and its
	// fake) deep-copies unstructured content via DeepCopyJSONValue, which only
	// handles JSON-native types — not arbitrary Go structs. ToUnstructured
	// honors the structs' json tags and yields plain map[string]interface{}.
	poolStatus, err := runtime.DefaultUnstructuredConverter.ToUnstructured(&pool)
	if err != nil {
		return fmt.Errorf("convert pool report: %w", err)
	}
	configStatus, err := runtime.DefaultUnstructuredConverter.ToUnstructured(&result.Config)
	if err != nil {
		return fmt.Errorf("convert config snapshot: %w", err)
	}
	failuresStatus, err := runtime.DefaultUnstructuredConverter.ToUnstructured(&result.Failures)
	if err != nil {
		return fmt.Errorf("convert failures: %w", err)
	}

	status := map[string]interface{}{
		"lastRunTime":   result.LastRunTime.UTC().Format(time.RFC3339),
		"lastRunStatus": result.LastRunStatus,
		"config":        configStatus,
		"pool":          poolStatus,
		"cluster": map[string]interface{}{
			"totalNodes":     int64(result.ClusterTotal),
			"unmanagedNodes": int64(result.ClusterTotal - pool.TotalNodes),
		},
		"failures": failuresStatus,
	}

	existing, err := w.client.Resource(reportGVR).Namespace(w.namespace).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		cr := &unstructured.Unstructured{}
		cr.SetGroupVersionKind(schema.GroupVersionKind{
			Group:   "remediation.crusoe.ai",
			Version: "v1alpha1",
			Kind:    "RemediationReport",
		})
		cr.SetName(name)
		cr.SetNamespace(w.namespace)
		cr.Object["status"] = status
		_, err = w.client.Resource(reportGVR).Namespace(w.namespace).Create(ctx, cr, metav1.CreateOptions{})
		return err
	}

	existing.Object["status"] = status
	_, err = w.client.Resource(reportGVR).Namespace(w.namespace).Update(ctx, existing, metav1.UpdateOptions{})
	return err
}
