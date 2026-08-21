package logging

import (
	"regexp"
	"strings"
	"sync"

	"github.com/coreos/go-systemd/v22/journal"
)

// stdLogPrefix matches the timestamp prefix produced by Go's log package
// with log.LstdFlags | log.LUTC: "YYYY/MM/DD HH:MM:SS ".
// The date/time parts use zero-padded values but Go's log may emit
// single-digit months/days without padding in some configurations.
var stdLogPrefix = regexp.MustCompile(`^\d{4}/\d{1,2}/\d{1,2} \d{1,2}:\d{2}:\d{2} `)

// stripTimestamp removes the leading "YYYY/MM/DD HH:MM:SS " prefix that
// Go's log package adds, so journald doesn't store a duplicate timestamp
// (journald already records its own _REALTIME_TIMESTAMP).
func stripTimestamp(msg string) string {
	return strings.TrimSpace(stdLogPrefix.ReplaceAllString(msg, ""))
}

// prefixIdentifier prepends "[identifier] " to the message so every
// journald entry is searchable by the identifier text in the Crusoe
// Managed Logs console. Lines that already start with the prefix or
// are empty are left unchanged.
func prefixIdentifier(identifier, msg string) string {
	if msg == "" {
		return ""
	}
	prefix := "[" + identifier + "] "
	if strings.HasPrefix(msg, prefix) {
		return msg
	}
	return prefix + msg
}

// JournalWriter implements io.Writer by sending each line to the systemd
// journal via the native D-Bus socket (/run/systemd/journal/socket). It is
// safe for concurrent use.
//
// The writer parses a severity level from the message content so that
// errors and warnings are tagged appropriately in the journal (and
// therefore in the Crusoe Managed Logs console, which normalises journald
// PRIORITY to the RFC 5424 severity taxonomy).
//
// If the journald socket is not available (e.g. running outside a systemd
// host), writes silently fall back to a no-op — the caller should always
// pair this writer with stdout via io.MultiWriter so logs are never lost.
type JournalWriter struct {
	identifier string
	once       sync.Once
	available  bool
}

// NewJournalWriter creates a writer that sends log lines to the systemd
// journal under the given syslog identifier (e.g. "crusoe-node-remediation").
func NewJournalWriter(identifier string) *JournalWriter {
	return &JournalWriter{identifier: identifier}
}

// Write sends p (a single log line, typically terminated by \n) to the
// systemd journal. It implements io.Writer.
func (w *JournalWriter) Write(p []byte) (int, error) {
	w.once.Do(func() {
		w.available = journal.Enabled()
	})

	if !w.available {
		// Journald socket not available — silently drop. The MultiWriter
		// still delivers the line to stdout.
		return len(p), nil
	}

	msg := stripTimestamp(string(p))
	if msg == "" {
		return len(p), nil
	}

	msg = prefixIdentifier(w.identifier, msg)

	journal.Send(msg, w.classify(msg), map[string]string{
		"SYSLOG_IDENTIFIER": w.identifier,
	})

	return len(p), nil
}

// classify infers a journal priority from common log message patterns.
// The standard library log package prepends a timestamp + flags, so we
// look for keywords that appear in the actual message body.
func (w *JournalWriter) classify(msg string) journal.Priority {
	lower := strings.ToLower(msg)

	// Order matters: check most specific first.
	switch {
	case strings.Contains(lower, "fatal") || strings.Contains(lower, "failed to read config") || strings.Contains(lower, "credential error"):
		return journal.PriCrit
	case strings.Contains(lower, "error:") || strings.Contains(lower, "error:"):
		return journal.PriErr
	case strings.Contains(lower, "warning:") || strings.Contains(lower, "warning:"):
		return journal.PriWarning
	case strings.Contains(lower, "config validation passed") || strings.Contains(lower, "completed successfully"):
		return journal.PriNotice
	default:
		return journal.PriInfo
	}
}
