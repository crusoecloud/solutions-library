package remediation

import (
	"context"
	"testing"
	"time"

	"crusoe-node-remediation/internal/constants"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic/fake"
)

func TestAggregatePoolStatus(t *testing.T) {
	statuses := []NodeStatus{
		{Name: "node-1", Ready: true, Phase: constants.PhaseMonitored, Managed: true, Action: ActionNone},
		{Name: "node-2", Ready: true, Phase: constants.PhaseCordoned, Managed: true, Action: ActionRemediate},
		{Name: "node-3", Ready: false, Phase: constants.PhaseDraining, Managed: true, Action: ActionRemediate},
		{Name: "node-4", Ready: true, Phase: constants.PhaseMonitored, Managed: true, InCooldown: true, Excluded: true, ExcludeReason: ExcludeCooldown},
		{Name: "node-5", Ready: true, Phase: constants.PhaseMonitored, Excluded: true, ExcludeReason: ExcludeSelfNode},
		{Name: "node-6", Ready: true, Phase: constants.PhaseMonitored, Excluded: true, ExcludeReason: ExcludeUndetermined},
		{Name: "node-7", Ready: true, Phase: constants.PhaseMonitored, Managed: true, Action: ActionCordon, GuardrailBlocked: true},
	}

	report := aggregatePoolStatus("0fe3d21c", 7, statuses)

	if report.NodepoolID != "0fe3d21c" {
		t.Errorf("NodepoolID = %q, want 0fe3d21c", report.NodepoolID)
	}
	if report.TotalNodes != 7 {
		t.Errorf("TotalNodes = %d, want 7", report.TotalNodes)
	}
	if report.ReadyNodes != 6 {
		t.Errorf("ReadyNodes = %d, want 6", report.ReadyNodes)
	}
	if report.NotReadyNodes != 1 {
		t.Errorf("NotReadyNodes = %d, want 1", report.NotReadyNodes)
	}
	if report.RemediatingNodes != 2 {
		t.Errorf("RemediatingNodes = %d, want 2 (cordoned + draining)", report.RemediatingNodes)
	}
	if report.PendingRemediation != 1 {
		t.Errorf("PendingRemediation = %d, want 1 (node-2 in PhaseCordoned)", report.PendingRemediation)
	}
	if report.CooldownNodes != 1 {
		t.Errorf("CooldownNodes = %d, want 1 (node-4 in cooldown)", report.CooldownNodes)
	}
	if report.MonitoredNodes != 2 {
		t.Errorf("MonitoredNodes = %d, want 2 (node-1 + node-7: managed, PhaseMonitored, not in cooldown/active)", report.MonitoredNodes)
	}
	if report.ManagedNodes != 5 {
		t.Errorf("ManagedNodes = %d, want 5 (node-1,2,3,4,7 have Managed=true)", report.ManagedNodes)
	}
	if report.UnmanagedNodes != 2 {
		t.Errorf("UnmanagedNodes = %d, want 2 (node-5 + node-6: managed=false)", report.UnmanagedNodes)
	}
	if report.UndeterminedNodes != 1 {
		t.Errorf("UndeterminedNodes = %d, want 1 (node-6)", report.UndeterminedNodes)
	}
	if report.ExcludedNode != "node-5" {
		t.Errorf("ExcludedNode = %q, want node-5 (self-node)", report.ExcludedNode)
	}
	if report.GuardrailBlocked != 1 {
		t.Errorf("GuardrailBlocked = %d, want 1 (node-7)", report.GuardrailBlocked)
	}
	if report.OkNodes != 1 {
		t.Errorf("OkNodes = %d, want 1 (node-1: managed, ActionNone, not active/cooldown)", report.OkNodes)
	}
	if report.DueNodes != 1 {
		t.Errorf("DueNodes = %d, want 1 (node-7: managed, ActionCordon, not active/cooldown; node-2,3 excluded as active)", report.DueNodes)
	}
}

// ── ManagedNodes counter tests ────────────────────────────────────

func TestAggregatePoolStatus_AllManaged(t *testing.T) {
	// All nodes have managed=true → ManagedNodes = total, UnmanagedNodes = 0
	statuses := []NodeStatus{
		{Name: "n1", Ready: true, Phase: constants.PhaseMonitored, Managed: true},
		{Name: "n2", Ready: true, Phase: constants.PhaseMonitored, Managed: true},
		{Name: "n3", Ready: true, Phase: constants.PhaseDraining, Managed: true},
	}

	report := aggregatePoolStatus("pool", 3, statuses)

	if report.ManagedNodes != 3 {
		t.Errorf("ManagedNodes = %d, want 3 (all managed)", report.ManagedNodes)
	}
	if report.UnmanagedNodes != 0 {
		t.Errorf("UnmanagedNodes = %d, want 0 (none unmanaged)", report.UnmanagedNodes)
	}
}

func TestAggregatePoolStatus_AllUnmanaged(t *testing.T) {
	// No nodes have managed=true → ManagedNodes = 0, UnmanagedNodes = total
	statuses := []NodeStatus{
		{Name: "n1", Ready: true, Phase: constants.PhaseMonitored, Managed: false},
		{Name: "n2", Ready: true, Phase: constants.PhaseMonitored, Managed: false},
	}

	report := aggregatePoolStatus("pool", 2, statuses)

	if report.ManagedNodes != 0 {
		t.Errorf("ManagedNodes = %d, want 0 (none managed)", report.ManagedNodes)
	}
	if report.UnmanagedNodes != 2 {
		t.Errorf("UnmanagedNodes = %d, want 2 (all unmanaged)", report.UnmanagedNodes)
	}
	if report.MonitoredNodes != 0 {
		t.Errorf("MonitoredNodes = %d, want 0 (unmanaged nodes are not monitored)", report.MonitoredNodes)
	}
}

func TestAggregatePoolStatus_MixedManaged(t *testing.T) {
	// Mix of managed and unmanaged
	statuses := []NodeStatus{
		{Name: "n1", Ready: true, Phase: constants.PhaseMonitored, Managed: true},
		{Name: "n2", Ready: true, Phase: constants.PhaseMonitored, Managed: false},
		{Name: "n3", Ready: true, Phase: constants.PhaseDraining, Managed: true},
		{Name: "n4", Ready: true, Phase: constants.PhaseMonitored, Managed: false},
	}

	report := aggregatePoolStatus("pool", 4, statuses)

	if report.ManagedNodes != 2 {
		t.Errorf("ManagedNodes = %d, want 2 (n1, n3)", report.ManagedNodes)
	}
	if report.UnmanagedNodes != 2 {
		t.Errorf("UnmanagedNodes = %d, want 2 (n2, n4)", report.UnmanagedNodes)
	}
	if report.MonitoredNodes != 1 {
		t.Errorf("MonitoredNodes = %d, want 1 (only n1: managed, PhaseMonitored, not active)", report.MonitoredNodes)
	}
}

// ── MonitoredNodes counter tests ──────────────────────────────────

func TestAggregatePoolStatus_MonitoredExcludesActivePhases(t *testing.T) {
	// Nodes in active phases should NOT be counted as monitored
	statuses := []NodeStatus{
		{Name: "n1", Ready: true, Phase: constants.PhaseMonitored, Managed: true},
		{Name: "n2", Ready: true, Phase: constants.PhaseCordoned, Managed: true},
		{Name: "n3", Ready: true, Phase: constants.PhaseDraining, Managed: true},
		{Name: "n4", Ready: true, Phase: constants.PhaseActionRunning, Managed: true},
		{Name: "n5", Ready: true, Phase: constants.PhaseUncordoning, Managed: true},
	}

	report := aggregatePoolStatus("pool", 5, statuses)

	if report.MonitoredNodes != 1 {
		t.Errorf("MonitoredNodes = %d, want 1 (only n1 in PhaseMonitored)", report.MonitoredNodes)
	}
	if report.RemediatingNodes != 4 {
		t.Errorf("RemediatingNodes = %d, want 4 (n2-n5 in active phases)", report.RemediatingNodes)
	}
}

func TestAggregatePoolStatus_MonitoredExcludesCooldown(t *testing.T) {
	// Nodes in cooldown should NOT be counted as monitored
	statuses := []NodeStatus{
		{Name: "n1", Ready: true, Phase: constants.PhaseMonitored, Managed: true},
		{Name: "n2", Ready: true, Phase: constants.PhaseMonitored, Managed: true, InCooldown: true, Excluded: true, ExcludeReason: ExcludeCooldown},
	}

	report := aggregatePoolStatus("pool", 2, statuses)

	if report.MonitoredNodes != 1 {
		t.Errorf("MonitoredNodes = %d, want 1 (n2 in cooldown, not monitored)", report.MonitoredNodes)
	}
	if report.CooldownNodes != 1 {
		t.Errorf("CooldownNodes = %d, want 1", report.CooldownNodes)
	}
}

func TestAggregatePoolStatus_MonitoredExcludesUndetermined(t *testing.T) {
	// Undetermined nodes should NOT be counted as monitored
	statuses := []NodeStatus{
		{Name: "n1", Ready: true, Phase: constants.PhaseMonitored, Managed: true},
		{Name: "n2", Ready: true, Phase: constants.PhaseMonitored, Managed: true, Excluded: true, ExcludeReason: ExcludeUndetermined},
	}

	report := aggregatePoolStatus("pool", 2, statuses)

	if report.MonitoredNodes != 1 {
		t.Errorf("MonitoredNodes = %d, want 1 (n2 undetermined, not monitored)", report.MonitoredNodes)
	}
	if report.UndeterminedNodes != 1 {
		t.Errorf("UndeterminedNodes = %d, want 1", report.UndeterminedNodes)
	}
}

func TestAggregatePoolStatus_MonitoredIncludesSelfNode(t *testing.T) {
	// Self-node IS counted as monitored (it's healthy, just not a remediation target)
	statuses := []NodeStatus{
		{Name: "n1", Ready: true, Phase: constants.PhaseMonitored, Managed: true},
		{Name: "n2", Ready: true, Phase: constants.PhaseMonitored, Managed: true, Excluded: true, ExcludeReason: ExcludeSelfNode},
	}

	report := aggregatePoolStatus("pool", 2, statuses)

	if report.MonitoredNodes != 2 {
		t.Errorf("MonitoredNodes = %d, want 2 (self-node n2 is still monitored — healthy, managed, not in active phase)", report.MonitoredNodes)
	}
	if report.ExcludedNode != "n2" {
		t.Errorf("ExcludedNode = %q, want n2", report.ExcludedNode)
	}
}

func TestAggregatePoolStatus_MonitoredRequiresManaged(t *testing.T) {
	// Unmanaged nodes (managed=false) should NOT be counted as monitored
	// even if they're healthy and in PhaseMonitored
	statuses := []NodeStatus{
		{Name: "n1", Ready: true, Phase: constants.PhaseMonitored, Managed: true},
		{Name: "n2", Ready: true, Phase: constants.PhaseMonitored, Managed: false},
	}

	report := aggregatePoolStatus("pool", 2, statuses)

	if report.MonitoredNodes != 1 {
		t.Errorf("MonitoredNodes = %d, want 1 (n2 is unmanaged, not monitored)", report.MonitoredNodes)
	}
	if report.UnmanagedNodes != 1 {
		t.Errorf("UnmanagedNodes = %d, want 1 (n2)", report.UnmanagedNodes)
	}
}

// ── Column sum verification ───────────────────────────────────────

func TestAggregatePoolStatus_ColumnsSumToTotal(t *testing.T) {
	// Verify: remediating + cooldown + unmanaged + undetermined + OK + DUE = total
	// (monitored overlaps with OK/DUE, so it's not in the sum)
	// (self-node is counted in OK or DUE depending on its action tier)
	statuses := []NodeStatus{
		{Name: "n1", Ready: true, Phase: constants.PhaseMonitored, Managed: true, Action: ActionNone},
		{Name: "n2", Ready: true, Phase: constants.PhaseDraining, Managed: true, Action: ActionRemediate},
		{Name: "n3", Ready: true, Phase: constants.PhaseMonitored, Managed: true, InCooldown: true, Excluded: true, ExcludeReason: ExcludeCooldown, Action: ActionRemediate},
		{Name: "n4", Ready: true, Phase: constants.PhaseMonitored, Managed: true, Excluded: true, ExcludeReason: ExcludeSelfNode, Action: ActionNone},
		{Name: "n5", Ready: true, Phase: constants.PhaseMonitored, Managed: false, Action: ActionNone},
		{Name: "n6", Ready: true, Phase: constants.PhaseCordoned, Managed: true, Action: ActionRemediate},
		{Name: "n7", Ready: true, Phase: constants.PhaseMonitored, Managed: true, Excluded: true, ExcludeReason: ExcludeUndetermined, Action: ActionNone},
	}

	report := aggregatePoolStatus("pool", 7, statuses)

	sum := report.RemediatingNodes + report.CooldownNodes + report.UnmanagedNodes + report.UndeterminedNodes + report.OkNodes + report.DueNodes
	if sum != report.TotalNodes {
		t.Errorf("column sum = %d (remediating=%d + cooldown=%d + unmanaged=%d + undetermined=%d + ok=%d + due=%d), want total=%d",
			sum, report.RemediatingNodes, report.CooldownNodes, report.UnmanagedNodes, report.UndeterminedNodes, report.OkNodes, report.DueNodes, report.TotalNodes)
	}
}

func TestAggregatePoolStatus_EmptyPool(t *testing.T) {
	report := aggregatePoolStatus("empty-pool", 0, nil)

	if report.TotalNodes != 0 {
		t.Errorf("TotalNodes = %d, want 0", report.TotalNodes)
	}
	if report.ReadyNodes != 0 {
		t.Errorf("ReadyNodes = %d, want 0", report.ReadyNodes)
	}
}

func TestRunResult_Struct(t *testing.T) {
	rr := RunResult{
		LastRunTime:   time.Date(2026, 8, 20, 0, 5, 0, 0, time.UTC),
		LastRunStatus: "succeeded",
		ClusterTotal:  12,
		Config: ConfigSnapshot{
			ActionType:          "vm-reset",
			DryRun:              false,
			GuardrailsGlobalMax: 1,
		},
		PoolReports: []PoolReport{
			{NodepoolID: "0fe3d21c", TotalNodes: 8},
		},
		Failures: []NodeFailure{
			{Node: "np-3", Error: "timeout", Attempts: 3},
		},
	}

	if rr.ClusterTotal != 12 {
		t.Errorf("ClusterTotal = %d, want 12", rr.ClusterTotal)
	}
	if len(rr.PoolReports) != 1 {
		t.Fatalf("expected 1 pool report, got %d", len(rr.PoolReports))
	}
	if rr.PoolReports[0].NodepoolID != "0fe3d21c" {
		t.Errorf("NodepoolID = %q", rr.PoolReports[0].NodepoolID)
	}
	if len(rr.Failures) != 1 {
		t.Fatalf("expected 1 failure, got %d", len(rr.Failures))
	}
	if rr.Failures[0].Node != "np-3" {
		t.Errorf("failure node = %q, want np-3", rr.Failures[0].Node)
	}
	if rr.Config.ActionType != "vm-reset" {
		t.Errorf("Config.ActionType = %q, want vm-reset", rr.Config.ActionType)
	}
}

func TestReportWriter_WriteReport_CreatesNewCR(t *testing.T) {
	gvr := schema.GroupVersionResource{
		Group:    "remediation.crusoe.ai",
		Version:  "v1alpha1",
		Resource: "remediationreports",
	}
	scheme := runtime.NewScheme()
	client := fake.NewSimpleDynamicClientWithCustomListKinds(scheme,
		map[schema.GroupVersionResource]string{gvr: "RemediationReportList"})
	writer := NewReportWriter(client, "crusoe-node-remediation")

	result := RunResult{
		LastRunTime:   time.Date(2026, 8, 20, 0, 5, 0, 0, time.UTC),
		LastRunStatus: "succeeded",
		ClusterTotal:  12,
		Config:        ConfigSnapshot{ActionType: "vm-reset"},
		PoolReports: []PoolReport{
			{
				NodepoolID:       "0fe3d21c",
				TotalNodes:       8,
				ReadyNodes:       7,
				RemediatingNodes: 1,
			},
		},
	}

	err := writer.WriteReport(context.Background(), result)
	if err != nil {
		t.Fatalf("WriteReport error: %v", err)
	}

	cr, err := client.Resource(gvr).Namespace("crusoe-node-remediation").Get(
		context.Background(), "np-0fe3d21c", metav1.GetOptions{},
	)
	if err != nil {
		t.Fatalf("failed to get CR: %v", err)
	}

	status := cr.Object["status"].(map[string]interface{})
	if status["lastRunStatus"] != "succeeded" {
		t.Errorf("lastRunStatus = %v, want succeeded", status["lastRunStatus"])
	}
	if status["config"] == nil {
		t.Error("config should be present in status")
	}
	if status["failures"] == nil {
		t.Error("failures should be present in status")
	}
}

func TestReportWriter_WriteReport_UpdatesExistingCR(t *testing.T) {
	gvr := schema.GroupVersionResource{
		Group:    "remediation.crusoe.ai",
		Version:  "v1alpha1",
		Resource: "remediationreports",
	}
	scheme := runtime.NewScheme()
	client := fake.NewSimpleDynamicClientWithCustomListKinds(scheme,
		map[schema.GroupVersionResource]string{gvr: "RemediationReportList"})
	writer := NewReportWriter(client, "crusoe-node-remediation")

	result1 := RunResult{
		LastRunTime:   time.Date(2026, 8, 20, 0, 5, 0, 0, time.UTC),
		LastRunStatus: "succeeded",
		PoolReports:   []PoolReport{{NodepoolID: "0fe3d21c", TotalNodes: 8, ReadyNodes: 8}},
	}
	if err := writer.WriteReport(context.Background(), result1); err != nil {
		t.Fatalf("first WriteReport: %v", err)
	}

	result2 := RunResult{
		LastRunTime:   time.Date(2026, 8, 20, 0, 10, 0, 0, time.UTC),
		LastRunStatus: "failed",
		PoolReports:   []PoolReport{{NodepoolID: "0fe3d21c", TotalNodes: 8, ReadyNodes: 7}},
	}
	if err := writer.WriteReport(context.Background(), result2); err != nil {
		t.Fatalf("second WriteReport: %v", err)
	}

	cr, err := client.Resource(gvr).Namespace("crusoe-node-remediation").Get(
		context.Background(), "np-0fe3d21c", metav1.GetOptions{},
	)
	if err != nil {
		t.Fatalf("failed to get CR: %v", err)
	}

	status := cr.Object["status"].(map[string]interface{})
	if status["lastRunStatus"] != "failed" {
		t.Errorf("lastRunStatus = %v, want failed (should be updated)", status["lastRunStatus"])
	}
}

func TestReportWriter_WriteReport_MultiplePools(t *testing.T) {
	gvr := schema.GroupVersionResource{
		Group:    "remediation.crusoe.ai",
		Version:  "v1alpha1",
		Resource: "remediationreports",
	}
	scheme := runtime.NewScheme()
	client := fake.NewSimpleDynamicClientWithCustomListKinds(scheme,
		map[schema.GroupVersionResource]string{gvr: "RemediationReportList"})
	writer := NewReportWriter(client, "crusoe-node-remediation")

	result := RunResult{
		LastRunStatus: "succeeded",
		PoolReports: []PoolReport{
			{NodepoolID: "pool-aaa", TotalNodes: 4},
			{NodepoolID: "pool-bbb", TotalNodes: 8},
		},
	}

	if err := writer.WriteReport(context.Background(), result); err != nil {
		t.Fatalf("WriteReport error: %v", err)
	}

	for _, name := range []string{"np-pool-aaa", "np-pool-bbb"} {
		_, err := client.Resource(gvr).Namespace("crusoe-node-remediation").Get(
			context.Background(), name, metav1.GetOptions{},
		)
		if err != nil {
			t.Errorf("expected CR %q to exist: %v", name, err)
		}
	}
}

// ── Multi-pool aggregation tests ──────────────────────────────────

func TestAggregatePoolStatus_TwoPools_IndependentCounts(t *testing.T) {
	// Two pools with different node states — verify counts are independent
	poolA := []NodeStatus{
		{Name: "a1", Ready: true, Phase: constants.PhaseMonitored, Managed: true, Action: ActionNone},
		{Name: "a2", Ready: true, Phase: constants.PhaseDraining, Managed: true, Action: ActionRemediate},
		{Name: "a3", Ready: true, Phase: constants.PhaseMonitored, Managed: true, InCooldown: true, Excluded: true, ExcludeReason: ExcludeCooldown, Action: ActionRemediate},
	}

	poolB := []NodeStatus{
		{Name: "b1", Ready: true, Phase: constants.PhaseMonitored, Managed: true, Action: ActionCordon},
		{Name: "b2", Ready: false, Phase: constants.PhaseActionRunning, Managed: true, Action: ActionRemediate},
	}

	reportA := aggregatePoolStatus("pool-a", 3, poolA)
	reportB := aggregatePoolStatus("pool-b", 2, poolB)

	// Pool A: 1 ok, 0 due (a2 is active, a3 is cooldown), 1 remediating, 1 cooldown
	if reportA.OkNodes != 1 {
		t.Errorf("poolA OkNodes = %d, want 1 (a1)", reportA.OkNodes)
	}
	if reportA.DueNodes != 0 {
		t.Errorf("poolA DueNodes = %d, want 0 (a2 active, a3 cooldown)", reportA.DueNodes)
	}
	if reportA.RemediatingNodes != 1 {
		t.Errorf("poolA RemediatingNodes = %d, want 1 (a2 draining)", reportA.RemediatingNodes)
	}
	if reportA.CooldownNodes != 1 {
		t.Errorf("poolA CooldownNodes = %d, want 1 (a3)", reportA.CooldownNodes)
	}

	// Pool B: 0 ok, 0 due (b1 is active? no — PhaseMonitored with ActionCordon), 1 remediating, 0 cooldown
	// b1: PhaseMonitored, ActionCordon, not active, not cooldown, managed → DUE
	// b2: PhaseActionRunning, active → remediating
	if reportB.OkNodes != 0 {
		t.Errorf("poolB OkNodes = %d, want 0", reportB.OkNodes)
	}
	if reportB.DueNodes != 1 {
		t.Errorf("poolB DueNodes = %d, want 1 (b1: ActionCordon, not active)", reportB.DueNodes)
	}
	if reportB.RemediatingNodes != 1 {
		t.Errorf("poolB RemediatingNodes = %d, want 1 (b2 action-running)", reportB.RemediatingNodes)
	}
	if reportB.NotReadyNodes != 1 {
		t.Errorf("poolB NotReadyNodes = %d, want 1 (b2 not ready)", reportB.NotReadyNodes)
	}
}

func TestAggregatePoolStatus_ThreePools_AllManaged(t *testing.T) {
	// Three pools, all nodes managed — verify managed counts per pool
	poolA := []NodeStatus{
		{Name: "a1", Ready: true, Phase: constants.PhaseMonitored, Managed: true, Action: ActionNone},
	}
	poolB := []NodeStatus{
		{Name: "b1", Ready: true, Phase: constants.PhaseMonitored, Managed: true, Action: ActionNone},
		{Name: "b2", Ready: true, Phase: constants.PhaseMonitored, Managed: true, Action: ActionNone},
	}
	poolC := []NodeStatus{
		{Name: "c1", Ready: true, Phase: constants.PhaseCordoned, Managed: true, Action: ActionRemediate},
		{Name: "c2", Ready: true, Phase: constants.PhaseMonitored, Managed: false, Action: ActionNone},
		{Name: "c3", Ready: true, Phase: constants.PhaseMonitored, Managed: true, InCooldown: true, Excluded: true, ExcludeReason: ExcludeCooldown, Action: ActionRemediate},
	}

	reportA := aggregatePoolStatus("pool-a", 1, poolA)
	reportB := aggregatePoolStatus("pool-b", 2, poolB)
	reportC := aggregatePoolStatus("pool-c", 3, poolC)

	if reportA.ManagedNodes != 1 {
		t.Errorf("poolA ManagedNodes = %d, want 1", reportA.ManagedNodes)
	}
	if reportB.ManagedNodes != 2 {
		t.Errorf("poolB ManagedNodes = %d, want 2", reportB.ManagedNodes)
	}
	if reportC.ManagedNodes != 2 {
		t.Errorf("poolC ManagedNodes = %d, want 2 (c1+c3 managed, c2 unmanaged)", reportC.ManagedNodes)
	}
	if reportC.UnmanagedNodes != 1 {
		t.Errorf("poolC UnmanagedNodes = %d, want 1 (c2)", reportC.UnmanagedNodes)
	}
}

func TestReportWriter_WriteReport_TwoPools_DistinctCRs(t *testing.T) {
	gvr := schema.GroupVersionResource{
		Group:    "remediation.crusoe.ai",
		Version:  "v1alpha1",
		Resource: "remediationreports",
	}
	scheme := runtime.NewScheme()
	client := fake.NewSimpleDynamicClientWithCustomListKinds(scheme,
		map[schema.GroupVersionResource]string{gvr: "RemediationReportList"})
	writer := NewReportWriter(client, "crusoe-node-remediation")

	result := RunResult{
		LastRunStatus: "succeeded",
		ClusterTotal:  10,
		PoolReports: []PoolReport{
			{
				NodepoolID:       "aaaa1111",
				TotalNodes:       4,
				ReadyNodes:       4,
				RemediatingNodes: 0,
				OkNodes:          3,
				DueNodes:         1,
				ManagedNodes:     4,
			},
			{
				NodepoolID:       "bbbb2222",
				TotalNodes:       6,
				ReadyNodes:       5,
				RemediatingNodes: 1,
				OkNodes:          2,
				DueNodes:         2,
				ManagedNodes:     6,
			},
		},
	}

	if err := writer.WriteReport(context.Background(), result); err != nil {
		t.Fatalf("WriteReport error: %v", err)
	}

	// Verify both CRs exist with correct pool data
	crA, err := client.Resource(gvr).Namespace("crusoe-node-remediation").Get(
		context.Background(), "np-aaaa1111", metav1.GetOptions{},
	)
	if err != nil {
		t.Fatalf("expected CR np-aaaa1111: %v", err)
	}
	statusA := crA.Object["status"].(map[string]interface{})
	poolA := statusA["pool"].(map[string]interface{})
	if int(poolA["totalNodes"].(int64)) != 4 {
		t.Errorf("poolA totalNodes = %v, want 4", poolA["totalNodes"])
	}
	if int(poolA["okNodes"].(int64)) != 3 {
		t.Errorf("poolA okNodes = %v, want 3", poolA["okNodes"])
	}

	crB, err := client.Resource(gvr).Namespace("crusoe-node-remediation").Get(
		context.Background(), "np-bbbb2222", metav1.GetOptions{},
	)
	if err != nil {
		t.Fatalf("expected CR np-bbbb2222: %v", err)
	}
	statusB := crB.Object["status"].(map[string]interface{})
	poolB := statusB["pool"].(map[string]interface{})
	if int(poolB["totalNodes"].(int64)) != 6 {
		t.Errorf("poolB totalNodes = %v, want 6", poolB["totalNodes"])
	}
	if int(poolB["remediatingNodes"].(int64)) != 1 {
		t.Errorf("poolB remediatingNodes = %v, want 1", poolB["remediatingNodes"])
	}

	// Verify cluster context shows total across all pools
	clusterA := statusA["cluster"].(map[string]interface{})
	if int(clusterA["totalNodes"].(int64)) != 10 {
		t.Errorf("clusterA totalNodes = %v, want 10", clusterA["totalNodes"])
	}
}

func TestReportWriter_WriteReport_TwoPools_UpdateBoth(t *testing.T) {
	gvr := schema.GroupVersionResource{
		Group:    "remediation.crusoe.ai",
		Version:  "v1alpha1",
		Resource: "remediationreports",
	}
	scheme := runtime.NewScheme()
	client := fake.NewSimpleDynamicClientWithCustomListKinds(scheme,
		map[schema.GroupVersionResource]string{gvr: "RemediationReportList"})
	writer := NewReportWriter(client, "crusoe-node-remediation")

	// First run — both pools succeed
	result1 := RunResult{
		LastRunStatus: "succeeded",
		PoolReports: []PoolReport{
			{NodepoolID: "aaaa1111", TotalNodes: 4, ReadyNodes: 4},
			{NodepoolID: "bbbb2222", TotalNodes: 6, ReadyNodes: 6},
		},
	}
	if err := writer.WriteReport(context.Background(), result1); err != nil {
		t.Fatalf("first WriteReport: %v", err)
	}

	// Second run — pool A fails, pool B succeeds
	result2 := RunResult{
		LastRunStatus: "failed",
		PoolReports: []PoolReport{
			{NodepoolID: "aaaa1111", TotalNodes: 4, ReadyNodes: 3, RemediatingNodes: 1},
			{NodepoolID: "bbbb2222", TotalNodes: 6, ReadyNodes: 6},
		},
	}
	if err := writer.WriteReport(context.Background(), result2); err != nil {
		t.Fatalf("second WriteReport: %v", err)
	}

	// Verify pool A was updated
	crA, _ := client.Resource(gvr).Namespace("crusoe-node-remediation").Get(
		context.Background(), "np-aaaa1111", metav1.GetOptions{},
	)
	statusA := crA.Object["status"].(map[string]interface{})
	if statusA["lastRunStatus"] != "failed" {
		t.Errorf("poolA lastRunStatus = %v, want failed (updated)", statusA["lastRunStatus"])
	}
	poolA := statusA["pool"].(map[string]interface{})
	if int(poolA["readyNodes"].(int64)) != 3 {
		t.Errorf("poolA readyNodes = %v, want 3 (updated)", poolA["readyNodes"])
	}

	// Verify pool B was updated
	crB, _ := client.Resource(gvr).Namespace("crusoe-node-remediation").Get(
		context.Background(), "np-bbbb2222", metav1.GetOptions{},
	)
	statusB := crB.Object["status"].(map[string]interface{})
	if statusB["lastRunStatus"] != "failed" {
		t.Errorf("poolB lastRunStatus = %v, want failed (updated)", statusB["lastRunStatus"])
	}
}
