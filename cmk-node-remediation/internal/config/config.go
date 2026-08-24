package config

import (
	"fmt"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// Duration is a time.Duration that supports YAML unmarshaling with days (d),
// hours (h), minutes (m), and seconds (s). Go's native time.Duration only
// supports h, m, s, ms, us, ns — not days. This custom type adds "d" support.
//
// Examples: "55d", "60d", "7d", "30m", "1h", "1800s", "1h30m"
type Duration time.Duration

// UnmarshalYAML implements yaml.Unmarshaler — parses duration strings with day support.
func (d *Duration) UnmarshalYAML(value *yaml.Node) error {
	var s string
	if err := value.Decode(&s); err != nil {
		return err
	}
	parsed, err := ParseDuration(s)
	if err != nil {
		return err
	}
	*d = Duration(parsed)
	return nil
}

// ParseDuration parses a duration string with support for days (d),
// hours (h), minutes (m), and seconds (s).
// Examples: "55d", "1h30m", "90m", "3600s", "1d12h"
func ParseDuration(s string) (time.Duration, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, fmt.Errorf("empty duration string")
	}

	// Replace "w" with "d" * 7 by expanding weeks into days
	// e.g., "2w" → "14d", "1w3d" → "10d"
	result := s
	for {
		idx := strings.IndexByte(result, 'w')
		if idx == -1 {
			break
		}
		start := idx - 1
		for start >= 0 && (result[start] >= '0' && result[start] <= '9') {
			start--
		}
		start++
		if start >= idx {
			return 0, fmt.Errorf("invalid duration %q: no number before 'w'", s)
		}
		weeksStr := result[start:idx]
		var weeks int
		if _, err := fmt.Sscanf(weeksStr, "%d", &weeks); err != nil {
			return 0, fmt.Errorf("invalid duration %q: cannot parse weeks %q", s, weeksStr)
		}
		days := weeks * 7
		replacement := fmt.Sprintf("%dd", days)
		result = result[:start] + replacement + result[idx+1:]
	}

	// Replace "d" with "h" * 24 by expanding days into hours
	// e.g., "55d" → "1320h", "1d12h" → "36h"
	for {
		idx := strings.IndexByte(result, 'd')
		if idx == -1 {
			break
		}
		// Find the number before 'd'
		start := idx - 1
		for start >= 0 && (result[start] >= '0' && result[start] <= '9') {
			start--
		}
		start++ // move to first digit
		if start >= idx {
			return 0, fmt.Errorf("invalid duration %q: no number before 'd'", s)
		}
		daysStr := result[start:idx]
		// Parse days and convert to hours
		var days int
		if _, err := fmt.Sscanf(daysStr, "%d", &days); err != nil {
			return 0, fmt.Errorf("invalid duration %q: cannot parse days %q", s, daysStr)
		}
		hours := days * 24
		replacement := fmt.Sprintf("%dh", hours)
		result = result[:start] + replacement + result[idx+1:]
	}

	// Now parse with Go's native time.ParseDuration (supports h, m, s, ms, us, ns)
	d, err := time.ParseDuration(result)
	if err != nil {
		return 0, fmt.Errorf("invalid duration %q: %w", s, err)
	}
	return d, nil
}

// ActionStepConfig holds a single step in a multi-step remediation action.
type ActionStepConfig struct {
	Type    string            `yaml:"type"`
	Timeout time.Duration     `yaml:"timeout"`
	Wait    time.Duration     `yaml:"wait,omitempty"`
	Params  map[string]string `yaml:"params,omitempty"`
}

// ActionConfig holds the configurable remediation action settings.
// Either Type (single step) or Steps (multi-step sequence) must be set, not both.
type ActionConfig struct {
	Type       string             `yaml:"type,omitempty"`
	Timeout    time.Duration      `yaml:"timeout,omitempty"`
	MaxRetries int                `yaml:"maxRetries"`
	Params     map[string]string  `yaml:"params,omitempty"`
	Steps      []ActionStepConfig `yaml:"steps,omitempty"`
}

// GuardrailsConfig holds concurrency limit settings.
type GuardrailsConfig struct {
	GlobalMaxCordoned         int  `yaml:"globalMaxCordoned"`
	GlobalMaxCordonedPercent  *int `yaml:"globalMaxCordonedPercent,omitempty"`
	PerPoolMaxCordoned        int  `yaml:"perPoolMaxCordoned"`
	PerPoolMaxCordonedPercent *int `yaml:"perPoolMaxCordonedPercent,omitempty"`
}

// NodeSelectorConfig holds label selector for target node discovery.
type NodeSelectorConfig struct {
	MatchLabels map[string]string `yaml:"matchLabels,omitempty"`
}

// Config holds all configuration for the node remediation manager.
type Config struct {
	Schedule                  string             `yaml:"schedule"`
	InstanceTypeFilter        string             `yaml:"instanceTypeFilter,omitempty"`
	CordonThreshold           Duration           `yaml:"cordonThreshold"`
	RemediationThreshold      Duration           `yaml:"remediationThreshold"`
	RemediationCooldown       Duration           `yaml:"remediationCooldown"`
	Action                    ActionConfig       `yaml:"action"`
	Guardrails                GuardrailsConfig   `yaml:"guardrails"`
	DrainTimeout              time.Duration      `yaml:"drainTimeout"`
	ForceAfterEvictionFailure bool               `yaml:"forceAfterEvictionFailure"`
	UseBuiltinSecret          bool               `yaml:"useBuiltinSecret"`
	CrusoeAPISecret           string             `yaml:"crusoeApiSecret"`
	CrusoeProjectID           string             `yaml:"crusoeProjectId"`
	DryRun                    bool               `yaml:"dryRun"`
	NodePriority              string             `yaml:"nodePriority,omitempty"`
	NodeSelector              NodeSelectorConfig `yaml:"nodeSelector,omitempty"`
}

// ValidStepTypes lists the supported remediation step types.
var ValidStepTypes = map[string]bool{
	"vm-reset":  true,
	"vm-stop":   true,
	"vm-start":  true,
	"vm-delete": true,
	"noop":      true,
}

func LoadFromYAML(data []byte) (*Config, error) {
	cfg := defaultConfig()
	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config YAML: %w", err)
	}
	return cfg, nil
}

// CordonDuration returns the cordon threshold as a time.Duration.
func (c *Config) CordonDuration() time.Duration { return time.Duration(c.CordonThreshold) }

// RemediationThresholdDuration returns the remediation threshold as a time.Duration.
func (c *Config) RemediationThresholdDuration() time.Duration {
	return time.Duration(c.RemediationThreshold)
}

// RemediationCooldownDuration returns the remediation cooldown as a time.Duration.
func (c *Config) RemediationCooldownDuration() time.Duration {
	return time.Duration(c.RemediationCooldown)
}

func defaultConfig() *Config {
	return &Config{
		Schedule:             "0 0 * * *",
		InstanceTypeFilter:   "b200.*",
		CordonThreshold:      Duration(55 * 24 * time.Hour), // 55 days
		RemediationThreshold: Duration(55 * 24 * time.Hour), // 55 days (equal to cordon = back-to-back)
		RemediationCooldown:  Duration(7 * 24 * time.Hour),  // 7 days
		Action: ActionConfig{
			Type:       "vm-reset",
			Timeout:    30 * time.Minute,
			MaxRetries: 3,
		},
		Guardrails: GuardrailsConfig{
			GlobalMaxCordoned:  5,
			PerPoolMaxCordoned: 2,
		},
		DrainTimeout:              120 * time.Minute,
		ForceAfterEvictionFailure: true,
		DryRun:                    false,
		NodePriority:              "highest-uptime",
	}
}

func (c *Config) Validate() error {
	if c.CordonThreshold > c.RemediationThreshold {
		return fmt.Errorf("cordonThreshold (%v) must not exceed remediationThreshold (%v)", c.CordonThreshold, c.RemediationThreshold)
	}
	if c.CordonThreshold <= 0 {
		return fmt.Errorf("cordonThreshold must be positive")
	}
	if c.RemediationCooldown < 0 {
		return fmt.Errorf("remediationCooldown must be non-negative")
	}
	if !c.UseBuiltinSecret {
		if c.CrusoeAPISecret == "" {
			return fmt.Errorf("crusoeApiSecret must be set (or enable useBuiltinSecret)")
		}
		if c.CrusoeProjectID == "" {
			return fmt.Errorf("crusoeProjectId must be set (or enable useBuiltinSecret)")
		}
	}

	hasType := c.Action.Type != ""
	hasSteps := len(c.Action.Steps) > 0
	if hasType && hasSteps {
		return fmt.Errorf("action.type and action.steps are mutually exclusive")
	}
	if !hasType && !hasSteps {
		return fmt.Errorf("either action.type or action.steps must be set")
	}
	if hasType && !ValidStepTypes[c.Action.Type] {
		return fmt.Errorf("invalid action type %q", c.Action.Type)
	}
	if hasSteps {
		for i, s := range c.Action.Steps {
			if !ValidStepTypes[s.Type] {
				return fmt.Errorf("invalid step type %q at index %d", s.Type, i)
			}
		}
	}
	if c.Action.MaxRetries <= 0 {
		return fmt.Errorf("action.maxRetries must be positive")
	}
	if c.Guardrails.GlobalMaxCordoned == 0 && c.Guardrails.GlobalMaxCordonedPercent == nil {
		return fmt.Errorf("either globalMaxCordoned or globalMaxCordonedPercent must be set")
	}
	if c.Guardrails.PerPoolMaxCordoned == 0 && c.Guardrails.PerPoolMaxCordonedPercent == nil {
		return fmt.Errorf("either perPoolMaxCordoned or perPoolMaxCordonedPercent must be set")
	}
	return nil
}
