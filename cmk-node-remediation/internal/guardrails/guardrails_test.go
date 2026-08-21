package guardrails

import (
	"testing"

	"crusoe-node-remediation/internal/config"
)

func TestCanCordonAbsoluteLimits(t *testing.T) {
	cfg := config.GuardrailsConfig{GlobalMaxCordoned: 5, PerPoolMaxCordoned: 2}
	checker := NewChecker(cfg)

	if !checker.CanCordon(4, 1, 100, 100) {
		t.Error("CanCordon(4, 1, 100, 100) = false, want true")
	}
	if checker.CanCordon(5, 1, 100, 100) {
		t.Error("CanCordon(5, 1, 100, 100) = true, want false (global limit)")
	}
	if checker.CanCordon(3, 2, 100, 100) {
		t.Error("CanCordon(3, 2, 100, 100) = true, want false (pool limit)")
	}
}

func TestCanCordonPercentLimits(t *testing.T) {
	globalPct := 20
	poolPct := 25
	cfg := config.GuardrailsConfig{
		GlobalMaxCordonedPercent:  &globalPct,
		PerPoolMaxCordonedPercent: &poolPct,
	}
	checker := NewChecker(cfg)

	if !checker.CanCordon(19, 24, 100, 100) {
		t.Error("CanCordon(19, 24, 100, 100) = false, want true")
	}
	if checker.CanCordon(20, 10, 100, 100) {
		t.Error("CanCordon(20, 10, 100, 100) = true, want false (global % limit)")
	}
}

func TestCanCordonGlobalPercentWithDifferentTotals(t *testing.T) {
	globalPct := 10
	cfg := config.GuardrailsConfig{
		GlobalMaxCordonedPercent: &globalPct,
		PerPoolMaxCordoned:       5,
	}
	checker := NewChecker(cfg)

	// 458 global total (like Hark), 50 pool total
	// 10% of 458 = 45.8 → ceil → 46 global max; 5 pool max
	if !checker.CanCordon(45, 4, 458, 50) {
		t.Error("CanCordon(45, 4, 458, 50) = false, want true")
	}
	if checker.CanCordon(46, 4, 458, 50) {
		t.Error("CanCordon(46, 4, 458, 50) = true, want false (global % limit)")
	}
}

func TestMaxAllowed(t *testing.T) {
	globalPct := 20
	poolPct := 25
	cfg := config.GuardrailsConfig{
		GlobalMaxCordoned:         5,
		GlobalMaxCordonedPercent:  &globalPct,
		PerPoolMaxCordoned:        2,
		PerPoolMaxCordonedPercent: &poolPct,
	}
	checker := NewChecker(cfg)

	gMax, pMax := checker.MaxAllowed(100, 100)
	if gMax != 5 {
		t.Errorf("globalMax = %d, want 5", gMax)
	}
	if pMax != 2 {
		t.Errorf("poolMax = %d, want 2", pMax)
	}

	gMax, pMax = checker.MaxAllowed(10, 8)
	if gMax != 2 {
		t.Errorf("globalMax = %d, want 2", gMax)
	}
	if pMax != 2 {
		t.Errorf("poolMax = %d, want 2", pMax)
	}
}

func TestPercentCeilingDivision(t *testing.T) {
	// Edge cases that were broken with floor division:
	// 9 nodes * 10% = 0.9 → ceiling → 1
	// 4 nodes * 20% = 0.8 → ceiling → 1
	// 3 nodes * 25% = 0.75 → ceiling → 1
	// 19 nodes * 5% = 0.95 → ceiling → 1

	tests := []struct {
		name      string
		pct       int
		total     int
		wantLimit int
	}{
		{"9 nodes, 10%", 10, 9, 1},
		{"4 nodes, 20%", 20, 4, 1},
		{"3 nodes, 25%", 25, 3, 1},
		{"19 nodes, 5%", 5, 19, 1},
		{"10 nodes, 10%", 10, 10, 1},
		{"15 nodes, 10%", 10, 15, 2},
		{"20 nodes, 5%", 5, 20, 1},
		{"100 nodes, 10%", 10, 100, 10},
		{"0 nodes, 10%", 10, 0, 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := config.GuardrailsConfig{
				GlobalMaxCordonedPercent: &tt.pct,
			}
			checker := NewChecker(cfg)
			gMax, _ := checker.MaxAllowed(tt.total, 0)
			if gMax != tt.wantLimit {
				t.Errorf("globalMax = %d, want %d", gMax, tt.wantLimit)
			}
		})
	}
}
