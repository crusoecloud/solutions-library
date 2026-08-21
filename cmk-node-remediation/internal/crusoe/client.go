package crusoe

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/antihax/optional"
	"github.com/crusoecloud/client-go/auth"
	crusoe "github.com/crusoecloud/client-go/swagger/v1"
)

// vmUptimeInfo is a lightweight struct for testing uptime calculation.
type vmUptimeInfo struct {
	ID        string
	CreatedAt string
}

// Client wraps the crusoecloud/client-go SDK for VM operations.
type Client struct {
	vmsAPI        *crusoe.VMsApiService
	vmOpsAPI      *crusoe.VMOperationsApiService
	identitiesAPI *crusoe.IdentitiesApiService
	projectID     string
}

// NewClient creates a new Crusoe API client using HMAC auth (access/secret key pair).
// The SDK's auth package signs each request with HMAC-SHA256, the same mechanism
// used by the Crusoe CLI. This avoids the need for a separate bearer token.
// Uses the v1 API (same as the Crusoe CLI) with default BasePath.
func NewClient(apiURL, accessKey, secretKey, projectID string) *Client {
	cfg := crusoe.NewConfiguration()
	if apiURL != "" {
		cfg.BasePath = apiURL
	}
	// Wrap the HTTP client's transport with HMAC signing (same as Crusoe CLI)
	if cfg.HTTPClient == nil {
		cfg.HTTPClient = &http.Client{}
	}
	cfg.HTTPClient.Transport = auth.NewAuthenticatingTransport(cfg.HTTPClient.Transport, accessKey, secretKey)

	apiClient := crusoe.NewAPIClient(cfg)

	return &Client{
		vmsAPI:        apiClient.VMsApi,
		vmOpsAPI:      apiClient.VMOperationsApi,
		identitiesAPI: apiClient.IdentitiesApi,
		projectID:     projectID,
	}
}

// swaggerError is the interface satisfied by the SDK's GenericSwaggerError.
// Using an interface allows testing without constructing the SDK type directly
// (its fields are unexported).
type swaggerError interface {
	Error() string
	Body() []byte
}

// detailError extracts the HTTP response body from a GenericSwaggerError
// to provide actionable diagnostics (e.g. "401 Unauthorized" → "invalid token").
// The swagger SDK's Error() only returns a generic status string; the Body()
// method has the actual API error message.
func detailError(err error) string {
	var se swaggerError
	if errors.As(err, &se) {
		body := se.Body()
		if len(body) > 0 {
			return fmt.Sprintf("%s [response: %s]", err.Error(), strings.TrimSpace(string(body)))
		}
	}
	return err.Error()
}

// IsNotFoundError returns true if the error is a 404/not-found from the Crusoe API.
// Uses errors.As to unwrap wrapped errors, then checks both the error message
// and response body for 404 or "not found" indicators.
func IsNotFoundError(err error) bool {
	if err == nil {
		return false
	}
	var se swaggerError
	if !errors.As(err, &se) {
		return false
	}
	errStr := strings.ToLower(se.Error())
	bodyStr := strings.ToLower(string(se.Body()))
	return strings.Contains(errStr, "404") ||
		strings.Contains(errStr, "not found") ||
		strings.Contains(bodyStr, "404") ||
		strings.Contains(bodyStr, "not found")
}

// VerifyAccess tests that the Crusoe API credentials are valid by calling
// the /users/identities endpoint (same as `crusoe whoami`). This is a
// lightweight call that doesn't require a project ID.
func (c *Client) VerifyAccess(ctx context.Context) error {
	user, _, err := c.identitiesAPI.GetUserIdentity(ctx)
	if err != nil {
		return fmt.Errorf("Crusoe API access verification failed: %s", detailError(err))
	}
	if user.Identity != nil {
		log.Printf("Crusoe API access verified (user: %s)", user.Identity.Email)
	} else {
		log.Printf("Crusoe API access verified")
	}
	return nil
}

// GetVMState queries the Crusoe API for a VM's current state.
func (c *Client) GetVMState(ctx context.Context, instanceID string) (string, error) {
	vm, _, err := c.vmsAPI.GetInstance(ctx, c.projectID, instanceID)
	if err != nil {
		return "", fmt.Errorf("Crusoe API GetInstance failed for VM %s: %w", instanceID, err)
	}
	return vm.State, nil
}

// RebootVM triggers a VM reset via the Crusoe API (Action: RESET).
// Returns the operation ID for async polling.
func (c *Client) RebootVM(ctx context.Context, instanceID string) (string, error) {
	return c.updateVMAction(ctx, instanceID, "RESET")
}

// StopVM stops a VM via the Crusoe API (Action: STOP).
// Returns the operation ID for async polling.
func (c *Client) StopVM(ctx context.Context, instanceID string) (string, error) {
	return c.updateVMAction(ctx, instanceID, "STOP")
}

// StartVM starts a VM via the Crusoe API (Action: START).
// Returns the operation ID for async polling.
func (c *Client) StartVM(ctx context.Context, instanceID string) (string, error) {
	return c.updateVMAction(ctx, instanceID, "START")
}

// DeleteVM deletes a VM via the Crusoe API.
// Returns the operation ID for async polling.
func (c *Client) DeleteVM(ctx context.Context, instanceID string) (string, error) {
	maxRetries := 3
	var lastErr error

	for attempt := 0; attempt < maxRetries; attempt++ {
		if attempt > 0 {
			backoff := time.Duration(1<<uint(attempt-1)) * time.Second
			select {
			case <-ctx.Done():
				return "", ctx.Err()
			case <-time.After(backoff):
			}
		}

		resp, _, err := c.vmsAPI.DeleteInstance(ctx, c.projectID, instanceID)
		if err == nil {
			if resp.Operation != nil {
				return resp.Operation.OperationId, nil
			}
			return "", nil
		}

		lastErr = err
		errStr := err.Error()
		if strings.Contains(errStr, "409") || // Conflict — another operation in progress
			strings.Contains(errStr, "429") ||
			strings.Contains(errStr, "500") ||
			strings.Contains(errStr, "502") ||
			strings.Contains(errStr, "503") ||
			strings.Contains(errStr, "504") {
			continue
		}

		return "", fmt.Errorf("Crusoe API delete failed for VM %s: %s", instanceID, detailError(err))
	}

	return "", fmt.Errorf("DeleteVM failed after %d retries: %s", maxRetries, detailError(lastErr))
}

// WaitForOperation polls the VMOperationsApi until the async operation completes.
func (c *Client) WaitForOperation(ctx context.Context, operationID string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	pollInterval := 10 * time.Second

	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		op, _, err := c.vmOpsAPI.GetComputeVMsInstancesOperation(ctx, c.projectID, operationID)
		if err != nil {
			log.Printf("warning: failed to poll operation %s: %v", operationID, err)
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(pollInterval):
			}
			continue
		}

		if op.CompletedAt != "" {
			return nil
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(pollInterval):
		}
	}

	return fmt.Errorf("operation %s did not complete within %v", operationID, timeout)
}

// updateVMAction is a helper for UpdateInstance with retry logic.
// Returns the operation ID for async polling.
func (c *Client) updateVMAction(ctx context.Context, instanceID, action string) (string, error) {
	patchReq := crusoe.InstancesPatchRequestV1{
		Action: action,
	}

	maxRetries := 3
	var lastErr error

	for attempt := 0; attempt < maxRetries; attempt++ {
		if attempt > 0 {
			backoff := time.Duration(1<<uint(attempt-1)) * time.Second
			select {
			case <-ctx.Done():
				return "", ctx.Err()
			case <-time.After(backoff):
			}
		}

		resp, _, err := c.vmsAPI.UpdateInstance(ctx, patchReq, c.projectID, instanceID)
		if err == nil {
			if resp.Operation != nil {
				return resp.Operation.OperationId, nil
			}
			return "", nil
		}

		lastErr = err
		errStr := err.Error()
		if strings.Contains(errStr, "409") || // Conflict — another operation in progress
			strings.Contains(errStr, "429") ||
			strings.Contains(errStr, "500") ||
			strings.Contains(errStr, "502") ||
			strings.Contains(errStr, "503") ||
			strings.Contains(errStr, "504") {
			continue
		}

		return "", fmt.Errorf("Crusoe API %s failed for VM %s: %s", action, instanceID, detailError(err))
	}

	return "", fmt.Errorf("%s failed after %d retries: %s", action, maxRetries, detailError(lastErr))
}

// calculateUptimes is a pure function for testing uptime calculation.
func calculateUptimes(vms []vmUptimeInfo, now time.Time) map[string]float64 {
	uptimes := make(map[string]float64)
	for _, vm := range vms {
		if vm.CreatedAt == "" {
			continue
		}
		createdAt, err := time.Parse(time.RFC3339, vm.CreatedAt)
		if err != nil {
			continue
		}
		uptime := now.Sub(createdAt).Hours() / 24.0
		uptimes[vm.ID] = uptime
	}
	return uptimes
}

// listInstances is a helper for testing that uses the SDK's ListInstances.
func (c *Client) listInstances(ctx context.Context) ([]crusoe.InstanceV1, error) {
	var allVMs []crusoe.InstanceV1
	nextToken := ""
	for {
		opts := &crusoe.VMsApiListInstancesOpts{
			Limit:     optional.NewString("500"),
			NextToken: optional.NewString(nextToken),
		}

		resp, _, err := c.vmsAPI.ListInstances(ctx, c.projectID, opts)
		if err != nil {
			return nil, fmt.Errorf("Crusoe API ListInstances failed: %w", err)
		}

		allVMs = append(allVMs, resp.Items...)

		if resp.NextPageToken == "" {
			break
		}
		nextToken = resp.NextPageToken
	}

	return allVMs, nil
}
