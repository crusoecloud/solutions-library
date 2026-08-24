package remediation

import (
	"testing"
	"time"
)

func TestHighestUptimePrioritizer(t *testing.T) {
	nodes := []NodeWithUptime{
		{Name: "node-1", Uptime: 30 * time.Minute},
		{Name: "node-2", Uptime: 2 * time.Hour},
		{Name: "node-3", Uptime: 1 * time.Hour},
	}

	p := highestUptime{}
	p.Sort(nodes)

	if nodes[0].Name != "node-2" {
		t.Errorf("first node = %s, want node-2 (2h uptime)", nodes[0].Name)
	}
	if nodes[1].Name != "node-3" {
		t.Errorf("second node = %s, want node-3 (1h uptime)", nodes[1].Name)
	}
	if nodes[2].Name != "node-1" {
		t.Errorf("third node = %s, want node-1 (30m uptime)", nodes[2].Name)
	}
}

func TestGetPrioritizerByName(t *testing.T) {
	tests := []struct {
		name    string
		want    string
		wantErr bool
	}{
		{"highest-uptime", "highest-uptime", false},
		{"", "highest-uptime", false}, // empty = default
		{"invalid", "", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p, err := GetPrioritizer(tt.name)
			if (err != nil) != tt.wantErr {
				t.Errorf("GetPrioritizer(%q) error = %v, wantErr = %v", tt.name, err, tt.wantErr)
				return
			}
			if !tt.wantErr && p.Name() != tt.want {
				t.Errorf("GetPrioritizer(%q).Name() = %q, want %q", tt.name, p.Name(), tt.want)
			}
		})
	}
}

func TestRegisterCustomPrioritizer(t *testing.T) {
	// Use a mock prioritizer for testing the registry
	mockP := &mockPrioritizer{name: "test-alpha"}
	RegisterPrioritizer(mockP)

	p, err := GetPrioritizer("test-alpha")
	if err != nil {
		t.Fatalf("GetPrioritizer(test-alpha) failed: %v", err)
	}
	if p.Name() != "test-alpha" {
		t.Errorf("Name() = %q, want test-alpha", p.Name())
	}
}

// mockPrioritizer is a test-only prioritizer for testing the registry.
type mockPrioritizer struct {
	name string
}

func (m *mockPrioritizer) Name() string                { return m.name }
func (m *mockPrioritizer) Sort(nodes []NodeWithUptime) {}
