package actions

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"crusoe-node-remediation/internal/crusoe"
)

// fakeCrusoeServer is an httptest.Server that fakes the Crusoe v1 API endpoints
// used by the VM action steps:
//
//	GET    /projects/{p}/compute/vms/instances/{id}            -> instance state
//	PATCH  /projects/{p}/compute/vms/instances/{id}            -> start/stop/reset action
//	DELETE /projects/{p}/compute/vms/instances/{id}            -> delete
//	GET    /projects/{p}/compute/vms/instances/operations/{id} -> operation status
//
// It lets tests exercise the real crusoe.Client (including SDK serialization)
// without touching production code or the real API.
type fakeCrusoeServer struct {
	t   *testing.T
	srv *httptest.Server

	mu sync.Mutex
	// vmState is returned by GET instance. Empty string means 404.
	vmState string
	// opCompleted controls whether GET operation returns completed_at set.
	opCompleted bool
	// actionErr, if non-nil, is the HTTP status code returned for PATCH/DELETE.
	actionErrStatus int
	// actionCalls records the action strings from PATCH bodies (and "DELETE").
	actionCalls []string
	// getStateCalls counts GET instance calls.
	getStateCalls int
}

func newFakeCrusoeServer(t *testing.T) *fakeCrusoeServer {
	t.Helper()
	f := &fakeCrusoeServer{t: t, vmState: "STATE_RUNNING", opCompleted: true}

	mux := http.NewServeMux()
	mux.HandleFunc("/", f.handle)
	f.srv = httptest.NewServer(mux)
	t.Cleanup(f.srv.Close)
	return f
}

// client returns a real crusoe.Client pointed at the fake server.
func (f *fakeCrusoeServer) client() *crusoe.Client {
	return crusoe.NewClient(f.srv.URL, "test-key", "test-secret", "proj-1")
}

func (f *fakeCrusoeServer) setVMState(state string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.vmState = state
}

func (f *fakeCrusoeServer) setActionErrStatus(status int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.actionErrStatus = status
}

func (f *fakeCrusoeServer) calls() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.actionCalls...)
}

func (f *fakeCrusoeServer) handle(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()

	w.Header().Set("Content-Type", "application/json")

	// Operation status: /projects/{p}/compute/vms/instances/operations/{opID}
	if strings.Contains(r.URL.Path, "/operations/") {
		op := map[string]any{
			"operation_id": "op-1",
			"state":        "STATE_DONE",
			"started_at":   time.Now().Add(-time.Minute).UTC().Format(time.RFC3339),
		}
		if f.opCompleted {
			op["completed_at"] = time.Now().UTC().Format(time.RFC3339)
		}
		_ = json.NewEncoder(w).Encode(op)
		return
	}

	// Instance: /projects/{p}/compute/vms/instances/{id}
	if !strings.Contains(r.URL.Path, "/instances/") {
		http.Error(w, `{"error":"unexpected path"}`, http.StatusNotFound)
		return
	}

	switch r.Method {
	case http.MethodGet:
		f.getStateCalls++
		if f.vmState == "" {
			w.WriteHeader(http.StatusNotFound)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "instance not found"})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"id":    "vm-001",
			"state": f.vmState,
		})

	case http.MethodPatch:
		if f.actionErrStatus != 0 {
			w.WriteHeader(f.actionErrStatus)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "action failed"})
			return
		}
		var body struct {
			Action string `json:"action"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.actionCalls = append(f.actionCalls, body.Action)
		// Transition VM state synchronously based on the action.
		switch body.Action {
		case "STOP":
			f.vmState = "STATE_STOPPED"
		case "START":
			f.vmState = "STATE_RUNNING"
		case "RESET":
			f.vmState = "STATE_RUNNING"
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"operation": map[string]any{"operation_id": "op-1"},
		})

	case http.MethodDelete:
		if f.actionErrStatus != 0 {
			w.WriteHeader(f.actionErrStatus)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "delete failed"})
			return
		}
		f.actionCalls = append(f.actionCalls, "DELETE")
		// Deleting removes the VM synchronously so subsequent GETs 404.
		f.vmState = ""
		_ = json.NewEncoder(w).Encode(map[string]any{
			"operation": map[string]any{"operation_id": "op-1"},
		})

	default:
		http.Error(w, fmt.Sprintf(`{"error":"unexpected method %s"}`, r.Method), http.StatusMethodNotAllowed)
	}
}
