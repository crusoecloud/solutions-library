package crusoe

import (
	"testing"
	"time"
)

func TestGetVMUptime(t *testing.T) {
	now := time.Now().UTC()

	vm1Created := now.AddDate(0, 0, -50).Format(time.RFC3339)
	vm2Created := now.AddDate(0, 0, -10).Format(time.RFC3339)

	uptimes := calculateUptimes([]vmUptimeInfo{
		{ID: "vm-001", CreatedAt: vm1Created},
		{ID: "vm-002", CreatedAt: vm2Created},
	}, now)

	if len(uptimes) != 2 {
		t.Fatalf("expected 2 VMs, got %d", len(uptimes))
	}

	if uptimes["vm-001"] < 49 || uptimes["vm-001"] > 51 {
		t.Errorf("vm-001 uptime = %.1f days, want ~50", uptimes["vm-001"])
	}
	if uptimes["vm-002"] < 9 || uptimes["vm-002"] > 11 {
		t.Errorf("vm-002 uptime = %.1f days, want ~10", uptimes["vm-002"])
	}
}

func TestGetVMUptimeEmptyList(t *testing.T) {
	now := time.Now().UTC()
	uptimes := calculateUptimes(nil, now)

	if len(uptimes) != 0 {
		t.Errorf("expected 0 VMs, got %d", len(uptimes))
	}
}

func TestGetVMUptimeInvalidTimestamp(t *testing.T) {
	now := time.Now().UTC()
	uptimes := calculateUptimes([]vmUptimeInfo{
		{ID: "vm-bad", CreatedAt: "not-a-timestamp"},
		{ID: "vm-good", CreatedAt: now.AddDate(0, 0, -30).Format(time.RFC3339)},
	}, now)

	if len(uptimes) != 1 {
		t.Fatalf("expected 1 VM (bad timestamp skipped), got %d", len(uptimes))
	}
	if _, ok := uptimes["vm-good"]; !ok {
		t.Error("vm-good should be in uptimes map")
	}
}

func TestNewClient(t *testing.T) {
	client := NewClient("https://api.crusoe.ai", "test-access", "test-secret", "proj-123")
	if client == nil {
		t.Fatal("NewClient returned nil")
	}
	if client.projectID != "proj-123" {
		t.Errorf("projectID = %q, want proj-123", client.projectID)
	}
}
