package logging

import (
	"bytes"
	"io"
	"testing"

	"github.com/coreos/go-systemd/v22/journal"
)

// ── NewJournalWriter ──────────────────────────────────────────────

func TestNewJournalWriter_SetsIdentifier(t *testing.T) {
	w := NewJournalWriter("crusoe-node-remediation")
	if w == nil {
		t.Fatal("expected non-nil writer")
	}
	if w.identifier != "crusoe-node-remediation" {
		t.Errorf("identifier = %q, want %q", w.identifier, "crusoe-node-remediation")
	}
}

// ── Write (io.Writer contract) ───────────────────────────────────

func TestWrite_ReturnsLengthAndNoError(t *testing.T) {
	w := NewJournalWriter("test")
	input := []byte("2026/08/19 12:00:00 crusoe-node-remediation starting\n")
	n, err := w.Write(input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if n != len(input) {
		t.Errorf("n = %d, want %d", n, len(input))
	}
}

func TestWrite_EmptyInput_DoesNotPanic(t *testing.T) {
	w := NewJournalWriter("test")
	n, err := w.Write([]byte{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if n != 0 {
		t.Errorf("n = %d, want 0", n)
	}
}

func TestWrite_WhitespaceOnly_DoesNotPanic(t *testing.T) {
	w := NewJournalWriter("test")
	input := []byte("   \n\t\n  ")
	n, err := w.Write(input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if n != len(input) {
		t.Errorf("n = %d, want %d", n, len(input))
	}
}

// When journald is not available (CI, non-systemd hosts), Write must
// silently drop the message without panicking. This is the critical
// safety property — the MultiWriter still delivers to stdout.
func TestWrite_JournaldUnavailable_SilentlyDrops(t *testing.T) {
	w := NewJournalWriter("test")
	// journal.Enabled() returns false in CI — Write should be a no-op
	input := []byte("some log line that won't reach journald\n")
	n, err := w.Write(input)
	if err != nil {
		t.Fatalf("unexpected error when journald unavailable: %v", err)
	}
	if n != len(input) {
		t.Errorf("n = %d, want %d (must report full length even when dropping)", n, len(input))
	}
}

// ── classify (severity mapping) ──────────────────────────────────

// ── prefixIdentifier ──────────────────────────────────────────────

func TestPrefixIdentifier(t *testing.T) {
	tests := []struct {
		name       string
		identifier string
		msg        string
		want       string
	}{
		{"typical line", "crusoe-node-remediation", "node np-1: phase=cordon starting", "[crusoe-node-remediation] node np-1: phase=cordon starting"},
		{"already has identifier", "crusoe-node-remediation", "[crusoe-node-remediation] starting", "[crusoe-node-remediation] starting"},
		{"starting line", "crusoe-node-remediation", "crusoe-node-remediation starting", "[crusoe-node-remediation] crusoe-node-remediation starting"},
		{"separator line", "crusoe-node-remediation", "────────────────────────", "[crusoe-node-remediation] ────────────────────────"},
		{"empty string", "crusoe-node-remediation", "", ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := prefixIdentifier(tt.identifier, tt.msg)
			if got != tt.want {
				t.Errorf("prefixIdentifier(%q, %q) = %q, want %q", tt.identifier, tt.msg, got, tt.want)
			}
		})
	}
}

// ── stripTimestamp ────────────────────────────────────────────────

func TestStripTimestamp(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{"standard log format", "2026/08/19 23:01:04 crusoe-node-remediation starting", "crusoe-node-remediation starting"},
		{"with trailing newline", "2026/08/19 23:01:04 crusoe-node-remediation starting\n", "crusoe-node-remediation starting"},
		{"single digit month/day", "2026/1/5 3:04:05 node np-1 cordoned", "node np-1 cordoned"},
		{"no timestamp", "crusoe-node-remediation starting", "crusoe-node-remediation starting"},
		{"empty string", "", ""},
		{"timestamp only", "2026/08/19 23:01:04 ", ""},
		{"separator line", "────────────────────────────────────────────────────────────", "────────────────────────────────────────────────────────────"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := stripTimestamp(tt.input)
			if got != tt.want {
				t.Errorf("stripTimestamp(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestClassify(t *testing.T) {
	w := NewJournalWriter("test")

	tests := []struct {
		name string
		msg  string
		want journal.Priority
	}{
		// Critical — fatal errors and startup failures
		{"fatal keyword", "2026/01/01 FATAL: something broke", journal.PriCrit},
		{"failed to read config", "failed to read config file: open: no such file", journal.PriCrit},
		{"credential error", "credential error: CRUSOE_ACCESS_KEY must be set", journal.PriCrit},

		// Error — runtime errors during remediation
		{"ERROR prefix", "ERROR: failed to cordon node np-1", journal.PriErr},
		{"error: lowercase", "error: drain timeout exceeded", journal.PriErr},

		// Warning — non-fatal issues
		{"warning: prefix", "warning: failed to create event", journal.PriWarning},
		{"WARNING: uppercase", "WARNING: guardrail exceeded", journal.PriWarning},

		// Notice — significant normal events
		{"config validation passed", "config validation passed", journal.PriNotice},
		{"completed successfully", "crusoe-node-remediation completed successfully", journal.PriNotice},

		// Info — default for normal operational messages
		{"starting message", "crusoe-node-remediation starting", journal.PriInfo},
		{"config line", "config: thresholds=(cordon=55d, remediation=55d)", journal.PriInfo},
		{"node cordoned", "node np-1 cordoned (uptime 55d)", journal.PriInfo},
		{"empty string", "", journal.PriInfo},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := w.classify(tt.msg)
			if got != tt.want {
				t.Errorf("classify(%q) = %v, want %v", tt.msg, got, tt.want)
			}
		})
	}
}

// ── Integration: MultiWriter ──────────────────────────────────────

// Verify that JournalWriter works correctly as part of io.MultiWriter,
// which is how main.go uses it. stdout should always receive the output;
// journald should not interfere even when unavailable.
func TestMultiWriter_StdoutAlwaysReceives(t *testing.T) {
	w := NewJournalWriter("test")
	var stdout bytes.Buffer
	mw := io.MultiWriter(&stdout, w)

	line := "crusoe-node-remediation starting\n"
	n, err := mw.Write([]byte(line))
	if err != nil {
		t.Fatalf("MultiWriter.Write error: %v", err)
	}
	if n != len(line) {
		t.Errorf("n = %d, want %d", n, len(line))
	}
	if stdout.String() != line {
		t.Errorf("stdout = %q, want %q", stdout.String(), line)
	}
}

// ── Concurrent writes ─────────────────────────────────────────────

func TestWrite_ConcurrentSafe(t *testing.T) {
	w := NewJournalWriter("test")
	done := make(chan struct{})

	for i := 0; i < 100; i++ {
		go func() {
			defer func() { done <- struct{}{} }()
			_, _ = w.Write([]byte("concurrent log line\n"))
		}()
	}

	for i := 0; i < 100; i++ {
		<-done
	}
}
