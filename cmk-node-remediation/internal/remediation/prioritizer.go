package remediation

import (
	"fmt"
	"sort"
	"time"
)

// NodeWithUptime pairs a discovered node with its uptime.
type NodeWithUptime struct {
	Name       string
	InstanceID string
	Uptime     time.Duration
}

// NodePrioritizer determines the order in which nodes are processed within a pool.
// Extensible — register custom prioritizers with RegisterPrioritizer.
type NodePrioritizer interface {
	// Sort reorders nodes in-place by priority.
	Sort(nodes []NodeWithUptime)
	// Name returns the prioritizer name (for logging).
	Name() string
}

// ── Built-in prioritizer ──────────────────────────────────────────

// highestUptime prioritizes nodes with the most uptime first (closest to threshold).
type highestUptime struct{}

func (highestUptime) Name() string { return "highest-uptime" }
func (highestUptime) Sort(nodes []NodeWithUptime) {
	sort.Slice(nodes, func(i, j int) bool {
		return nodes[i].Uptime > nodes[j].Uptime
	})
}

// ── Registry ─────────────────────────────────────────────────────

var prioritizers = map[string]NodePrioritizer{
	"highest-uptime": highestUptime{},
}

// RegisterPrioritizer adds a custom prioritizer (extensible).
func RegisterPrioritizer(p NodePrioritizer) {
	prioritizers[p.Name()] = p
}

// GetPrioritizer returns the prioritizer for the given name.
// Returns highest-uptime if name is empty.
func GetPrioritizer(name string) (NodePrioritizer, error) {
	if name == "" {
		return highestUptime{}, nil
	}
	p, ok := prioritizers[name]
	if !ok {
		return nil, fmt.Errorf("unknown nodePriority %q", name)
	}
	return p, nil
}

// SortNodesByUptime is a convenience function — sorts by highest uptime first.
func SortNodesByUptime(nodes []NodeWithUptime) {
	highestUptime{}.Sort(nodes)
}
