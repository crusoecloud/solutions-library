package remediation

import (
	"testing"
	"time"

	"crusoe-node-remediation/internal/constants"
)

func TestClassifyUptime(t *testing.T) {
	tests := []struct {
		name                 string
		uptime               time.Duration
		cordonThreshold      time.Duration
		remediationThreshold time.Duration
		want                 ActionTier
	}{
		{"below cordon", 40 * 24 * time.Hour, 55 * 24 * time.Hour, 60 * 24 * time.Hour, ActionNone},
		{"at cordon", 55 * 24 * time.Hour, 55 * 24 * time.Hour, 60 * 24 * time.Hour, ActionCordon},
		{"between", 57 * 24 * time.Hour, 55 * 24 * time.Hour, 60 * 24 * time.Hour, ActionCordon},
		{"at action", 60 * 24 * time.Hour, 55 * 24 * time.Hour, 60 * 24 * time.Hour, ActionRemediate},
		{"above action", 65 * 24 * time.Hour, 55 * 24 * time.Hour, 60 * 24 * time.Hour, ActionRemediate},
		// Hours and minutes
		{"below cordon (minutes)", 20 * time.Minute, 30 * time.Minute, 60 * time.Minute, ActionNone},
		{"at cordon (minutes)", 30 * time.Minute, 30 * time.Minute, 60 * time.Minute, ActionCordon},
		{"at action (minutes)", 60 * time.Minute, 30 * time.Minute, 60 * time.Minute, ActionRemediate},
		// Mixed units: 1h = 60m
		{"1h equals 60m for cordon", 60 * time.Minute, 60 * time.Minute, 2 * time.Hour, ActionCordon},
		{"1h equals 60m for action", 60 * time.Minute, 30 * time.Minute, 60 * time.Minute, ActionRemediate},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ClassifyUptime(tt.uptime, tt.cordonThreshold, tt.remediationThreshold)
			if got != tt.want {
				t.Errorf("ClassifyUptime(%v, %v, %v) = %v, want %v",
					tt.uptime, tt.cordonThreshold, tt.remediationThreshold, got, tt.want)
			}
		})
	}
}

func TestPhaseIsActive(t *testing.T) {
	active := []constants.Phase{
		constants.PhaseCordoned, constants.PhaseDraining, constants.PhaseForceDraining,
		constants.PhaseActionRunning, constants.PhaseUncordoning,
	}
	for _, p := range active {
		if !p.IsActive() {
			t.Errorf("Phase %v should be active", p)
		}
	}
	if constants.PhaseMonitored.IsActive() {
		t.Error("PhaseMonitored should not be active")
	}
}

func TestTaintKeyForPhase(t *testing.T) {
	tests := []struct {
		phase constants.Phase
		want  string
	}{
		{constants.PhaseCordoned, constants.TaintScheduled},
		{constants.PhaseDraining, constants.TaintDraining},
		{constants.PhaseForceDraining, constants.TaintDraining},
		{constants.PhaseActionRunning, constants.TaintMaintenance},
		{constants.PhaseUncordoning, constants.TaintScheduled},
	}
	for _, tt := range tests {
		t.Run(string(tt.phase), func(t *testing.T) {
			got := constants.TaintKeyForPhase(tt.phase)
			if got != tt.want {
				t.Errorf("TaintKeyForPhase(%v) = %q, want %q", tt.phase, got, tt.want)
			}
		})
	}
}
