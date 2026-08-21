package remediation

import (
	"time"
)

// ActionTier classifies what action to take based on uptime.
type ActionTier int

const (
	ActionNone      ActionTier = iota // < cordonThreshold
	ActionCordon                      // cordonThreshold <= uptime < remediationThreshold
	ActionRemediate                   // >= remediationThreshold
)

// ClassifyUptime determines the action tier for a node based on its uptime.
// All thresholds are time.Duration — supports days, hours, or minutes.
func ClassifyUptime(uptime time.Duration, cordonThreshold, remediationThreshold time.Duration) ActionTier {
	if uptime >= remediationThreshold {
		return ActionRemediate
	}
	if uptime >= cordonThreshold {
		return ActionCordon
	}
	return ActionNone
}
