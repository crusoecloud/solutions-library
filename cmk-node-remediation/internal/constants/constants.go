package constants

// Label key constants — all use crusoe.ai/ namespace with remediation.* prefix.
const (
	LabelRemediationManaged = "crusoe.ai/remediation.managed"
	LabelRemediationPhase   = "crusoe.ai/remediation.phase"

	// Existing CMK labels (not owned by us, just referenced)
	LabelNodepoolID   = "crusoe.ai/nodepool.id"
	LabelInstanceID   = "crusoe.ai/instance.id"
	LabelProjectID    = "crusoe.ai/project.id"
	LabelInstanceType = "beta.kubernetes.io/instance-type" // NOT crusoe.ai/vm.instance.type
)

// Annotation key constants.
const (
	AnnotationManagedBy           = "crusoe.ai/remediation.managed-by"
	AnnotationCordonedAt          = "crusoe.ai/remediation.cordoned-at"
	AnnotationCordonUptime        = "crusoe.ai/remediation.cordon-uptime"
	AnnotationDrainStartedAt      = "crusoe.ai/remediation.drain-started-at"
	AnnotationForceDrainStartedAt = "crusoe.ai/remediation.force-drain-started-at"
	AnnotationActionTriggeredAt   = "crusoe.ai/remediation.action-triggered-at"
	AnnotationActionType          = "crusoe.ai/remediation.action-type"
	AnnotationActionCompletedAt   = "crusoe.ai/remediation.action-completed-at"
	AnnotationUncordonedAt        = "crusoe.ai/remediation.uncordoned-at"
	AnnotationAttempt             = "crusoe.ai/remediation.attempt"
	AnnotationLastAction          = "crusoe.ai/remediation.last-action"

	ManagedByValue = "crusoe-node-remediation"
)

// Taint key constants.
const (
	TaintScheduled   = "crusoe.ai/remediation.scheduled"
	TaintDraining    = "crusoe.ai/remediation.draining"
	TaintMaintenance = "crusoe.ai/remediation.maintenance"
)

// Phase represents a node remediation state.
type Phase string

const (
	PhaseMonitored     Phase = "monitored"
	PhaseCordoned      Phase = "cordoned"
	PhaseDraining      Phase = "draining"
	PhaseForceDraining Phase = "force-draining"
	PhaseActionRunning Phase = "action-running"
	PhaseUncordoning   Phase = "uncordoning"
)

// IsActive returns true if the phase counts toward guardrail limits.
func (p Phase) IsActive() bool {
	switch p {
	case PhaseCordoned, PhaseDraining, PhaseForceDraining,
		PhaseActionRunning, PhaseUncordoning:
		return true
	default:
		return false
	}
}

// TaintKeyForPhase returns the taint key that should be present for a given phase.
func TaintKeyForPhase(phase Phase) string {
	switch phase {
	case PhaseCordoned, PhaseUncordoning:
		return TaintScheduled
	case PhaseDraining, PhaseForceDraining:
		return TaintDraining
	case PhaseActionRunning:
		return TaintMaintenance
	default:
		return TaintScheduled
	}
}
