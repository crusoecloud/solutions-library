package crusoe

import (
	"errors"
	"fmt"
	"testing"
)

// mockSwaggerError implements the swaggerError interface for testing.
// The SDK's GenericSwaggerError has unexported fields, so we can't
// construct it directly — but errors.As matches by interface, not type.
type mockSwaggerError struct {
	msg  string
	body []byte
}

func (e mockSwaggerError) Error() string { return e.msg }
func (e mockSwaggerError) Body() []byte  { return e.body }

func TestDetailError_WithSwaggerErrorBody(t *testing.T) {
	err := mockSwaggerError{
		msg:  "401 Unauthorized",
		body: []byte(`{"error":"invalid token"}`),
	}

	got := detailError(err)
	want := `401 Unauthorized [response: {"error":"invalid token"}]`
	if got != want {
		t.Errorf("detailError() = %q, want %q", got, want)
	}
}

func TestDetailError_WithEmptyBody(t *testing.T) {
	err := mockSwaggerError{
		msg:  "500 Internal Server Error",
		body: nil,
	}

	got := detailError(err)
	want := "500 Internal Server Error"
	if got != want {
		t.Errorf("detailError() = %q, want %q", got, want)
	}
}

func TestDetailError_WithWrappedSwaggerError(t *testing.T) {
	swaggerErr := mockSwaggerError{
		msg:  "403 Forbidden",
		body: []byte(`{"error":"insufficient permissions"}`),
	}
	wrapped := fmt.Errorf("context: %w", swaggerErr)

	got := detailError(wrapped)
	want := `context: 403 Forbidden [response: {"error":"insufficient permissions"}]`
	if got != want {
		t.Errorf("detailError() = %q, want %q", got, want)
	}
}

func TestDetailError_WithPlainError(t *testing.T) {
	err := errors.New("something went wrong")

	got := detailError(err)
	want := "something went wrong"
	if got != want {
		t.Errorf("detailError() = %q, want %q", got, want)
	}
}

func TestDetailError_WithWhitespaceInBody(t *testing.T) {
	err := mockSwaggerError{
		msg:  "400 Bad Request",
		body: []byte("  {\"error\":\"bad vm id\"}  \n"),
	}

	got := detailError(err)
	want := `400 Bad Request [response: {"error":"bad vm id"}]`
	if got != want {
		t.Errorf("detailError() = %q, want %q", got, want)
	}
}
