package actions

import (
	"context"
)

// NoopStep does nothing — used for dry-run mode and testing.
type NoopStep struct{}

func (s *NoopStep) Type() string { return "noop" }

func (s *NoopStep) Run(ctx context.Context, node NodeInfo, params map[string]string) error {
	return nil
}
