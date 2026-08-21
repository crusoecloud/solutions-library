package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func TestResolveProjectID(t *testing.T) {
	tests := []struct {
		name        string
		envValue    string
		configValue string
		want        string
	}{
		{name: "env var set, config empty", envValue: "env-project-123", configValue: "", want: "env-project-123"},
		{name: "env var set, config also set — env wins", envValue: "env-project-123", configValue: "config-project-456", want: "env-project-123"},
		{name: "env var empty, config set", envValue: "", configValue: "config-project-456", want: "config-project-456"},
		{name: "both empty", envValue: "", configValue: "", want: ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := resolveProjectID(tt.envValue, tt.configValue)
			if got != tt.want {
				t.Errorf("resolveProjectID(%q, %q) = %q, want %q", tt.envValue, tt.configValue, got, tt.want)
			}
		})
	}
}

// helperEnv builds an env lookup function from a map.
func helperEnv(envs map[string]string) func(string) string {
	return func(key string) string {
		return envs[key]
	}
}

func TestResolveCredentials_BuiltinSecretMode(t *testing.T) {
	// Simulates env vars from crusoe-secrets via secretKeyRef:
	// CRUSOE_ACCESS_KEY, CRUSOE_SECRET_KEY, CRUSOE_API_ENDPOINT, CRUSOE_PROJECT_ID
	envs := map[string]string{
		"CRUSOE_ACCESS_KEY":   "ak-builtin-123",
		"CRUSOE_SECRET_KEY":   "sk-builtin-456",
		"CRUSOE_API_ENDPOINT": "https://api.crusoecloud.com/v1alpha5",
		"CRUSOE_PROJECT_ID":   "proj-builtin-789",
	}

	creds, err := resolveCredentials(helperEnv(envs), "")
	if err != nil {
		t.Fatalf("expected no error, got: %v", err)
	}

	if creds.AccessKey != "ak-builtin-123" {
		t.Errorf("AccessKey = %q, want %q", creds.AccessKey, "ak-builtin-123")
	}
	if creds.SecretKey != "sk-builtin-456" {
		t.Errorf("SecretKey = %q, want %q", creds.SecretKey, "sk-builtin-456")
	}
	if creds.APIURL != "https://api.crusoecloud.com/v1alpha5" {
		t.Errorf("APIURL = %q, want %q", creds.APIURL, "https://api.crusoecloud.com/v1alpha5")
	}
	if creds.ProjectID != "proj-builtin-789" {
		t.Errorf("ProjectID = %q, want %q", creds.ProjectID, "proj-builtin-789")
	}
}

func TestResolveCredentials_CustomSecretMode(t *testing.T) {
	// Simulates env vars from a custom secret via secretKeyRef:
	// CRUSOE_ACCESS_KEY, CRUSOE_SECRET_KEY, CRUSOE_API_ENDPOINT (from api-url key)
	// Project ID comes from config, not env (custom mode doesn't set CRUSOE_PROJECT_ID)
	envs := map[string]string{
		"CRUSOE_ACCESS_KEY":   "ak-custom-123",
		"CRUSOE_SECRET_KEY":   "sk-custom-456",
		"CRUSOE_API_ENDPOINT": "https://api.cloud.crusoe.ai/v1alpha5",
		// CRUSOE_PROJECT_ID not set — falls back to config
	}

	creds, err := resolveCredentials(helperEnv(envs), "config-project-id")
	if err != nil {
		t.Fatalf("expected no error, got: %v", err)
	}

	if creds.AccessKey != "ak-custom-123" {
		t.Errorf("AccessKey = %q, want %q", creds.AccessKey, "ak-custom-123")
	}
	if creds.SecretKey != "sk-custom-456" {
		t.Errorf("SecretKey = %q, want %q", creds.SecretKey, "sk-custom-456")
	}
	if creds.APIURL != "https://api.cloud.crusoe.ai/v1alpha5" {
		t.Errorf("APIURL = %q, want %q", creds.APIURL, "https://api.cloud.crusoe.ai/v1alpha5")
	}
	if creds.ProjectID != "config-project-id" {
		t.Errorf("ProjectID = %q, want %q", creds.ProjectID, "config-project-id")
	}
}

func TestResolveCredentials_APIURLFallback(t *testing.T) {
	// When CRUSOE_API_ENDPOINT is empty, should fall back to default
	envs := map[string]string{
		"CRUSOE_ACCESS_KEY": "ak-123",
		"CRUSOE_SECRET_KEY": "sk-456",
		// CRUSOE_API_ENDPOINT not set
		"CRUSOE_PROJECT_ID": "proj-789",
	}

	creds, err := resolveCredentials(helperEnv(envs), "")
	if err != nil {
		t.Fatalf("expected no error, got: %v", err)
	}

	if creds.APIURL != "https://api.cloud.crusoe.ai/v1alpha5" {
		t.Errorf("APIURL = %q, want default %q", creds.APIURL, "https://api.cloud.crusoe.ai/v1alpha5")
	}
}

// writeSecretFiles writes credential files to a temp dir mimicking the projected
// volume mount of crusoe-secrets. Returns the dir path (caller should defer cleanup).
func writeSecretFiles(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	// Override BuiltinSecretPath for testing
	origPath := BuiltinSecretPath
	BuiltinSecretPath = dir
	t.Cleanup(func() { BuiltinSecretPath = origPath })

	for name, content := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0600); err != nil {
			t.Fatalf("failed to write %s: %v", name, err)
		}
	}
	return dir
}

func TestResolveCredentials_BuiltinSecretFromFile(t *testing.T) {
	// Simulates built-in mode: no env vars, credentials mounted as files
	// from crusoe-secrets projected volume
	writeSecretFiles(t, map[string]string{
		"CRUSOE_ACCESS_KEY":   "ak-builtin-file",
		"CRUSOE_SECRET_KEY":   "sk-builtin-file",
		"CRUSOE_API_ENDPOINT": "https://api.crusoecloud.com/v1alpha5",
		"CRUSOE_PROJECT_ID":   "proj-builtin-file",
	})

	// No env vars set — should read from files
	creds, err := resolveCredentials(helperEnv(map[string]string{}), "")
	if err != nil {
		t.Fatalf("expected no error, got: %v", err)
	}

	if creds.AccessKey != "ak-builtin-file" {
		t.Errorf("AccessKey = %q, want %q", creds.AccessKey, "ak-builtin-file")
	}
	if creds.SecretKey != "sk-builtin-file" {
		t.Errorf("SecretKey = %q, want %q", creds.SecretKey, "sk-builtin-file")
	}
	if creds.APIURL != "https://api.crusoecloud.com/v1alpha5" {
		t.Errorf("APIURL = %q, want %q", creds.APIURL, "https://api.crusoecloud.com/v1alpha5")
	}
	if creds.ProjectID != "proj-builtin-file" {
		t.Errorf("ProjectID = %q, want %q", creds.ProjectID, "proj-builtin-file")
	}
}

func TestResolveCredentials_EnvVarPriorityOverFile(t *testing.T) {
	// Both env var and file exist — env var should win
	writeSecretFiles(t, map[string]string{
		"CRUSOE_ACCESS_KEY":   "ak-from-file",
		"CRUSOE_SECRET_KEY":   "sk-from-file",
		"CRUSOE_API_ENDPOINT": "https://from-file.example.com",
		"CRUSOE_PROJECT_ID":   "proj-from-file",
	})

	envs := map[string]string{
		"CRUSOE_ACCESS_KEY":   "ak-from-env",
		"CRUSOE_SECRET_KEY":   "sk-from-env",
		"CRUSOE_API_ENDPOINT": "https://from-env.example.com",
		"CRUSOE_PROJECT_ID":   "proj-from-env",
	}

	creds, err := resolveCredentials(helperEnv(envs), "")
	if err != nil {
		t.Fatalf("expected no error, got: %v", err)
	}

	if creds.AccessKey != "ak-from-env" {
		t.Errorf("AccessKey = %q, want %q (env should win)", creds.AccessKey, "ak-from-env")
	}
	if creds.SecretKey != "sk-from-env" {
		t.Errorf("SecretKey = %q, want %q (env should win)", creds.SecretKey, "sk-from-env")
	}
	if creds.APIURL != "https://from-env.example.com" {
		t.Errorf("APIURL = %q, want %q (env should win)", creds.APIURL, "https://from-env.example.com")
	}
	if creds.ProjectID != "proj-from-env" {
		t.Errorf("ProjectID = %q, want %q (env should win)", creds.ProjectID, "proj-from-env")
	}
}

func TestResolveCredentials_MissingCredentials(t *testing.T) {
	// Neither env vars nor files — should error
	writeSecretFiles(t, map[string]string{}) // empty dir, no files

	_, err := resolveCredentials(helperEnv(map[string]string{}), "")
	if err == nil {
		t.Fatal("expected error for missing credentials, got nil")
	}
	if !strings.Contains(err.Error(), "CRUSOE_ACCESS_KEY") {
		t.Errorf("error should mention CRUSOE_ACCESS_KEY, got: %v", err)
	}
}

func TestLookupCredential_TrimsWhitespace(t *testing.T) {
	// File content with trailing newline should be trimmed
	writeSecretFiles(t, map[string]string{
		"CRUSOE_ACCESS_KEY": "ak-with-newline\n",
	})

	got := lookupCredential(helperEnv(map[string]string{}), "CRUSOE_ACCESS_KEY")
	if got != "ak-with-newline" {
		t.Errorf("lookupCredential = %q, want %q (whitespace should be trimmed)", got, "ak-with-newline")
	}
}

func TestResolveCredentials_ProjectIDEnvWinsOverConfig(t *testing.T) {
	// Both env and config set — env should win
	envs := map[string]string{
		"CRUSOE_ACCESS_KEY":   "ak-123",
		"CRUSOE_SECRET_KEY":   "sk-456",
		"CRUSOE_API_ENDPOINT": "https://api.crusoecloud.com/v1alpha5",
		"CRUSOE_PROJECT_ID":   "env-project-id",
	}

	creds, err := resolveCredentials(helperEnv(envs), "config-project-id")
	if err != nil {
		t.Fatalf("expected no error, got: %v", err)
	}

	if creds.ProjectID != "env-project-id" {
		t.Errorf("ProjectID = %q, want %q (env should win)", creds.ProjectID, "env-project-id")
	}
}

func TestResolveCredentials_MissingAccessKey(t *testing.T) {
	envs := map[string]string{
		"CRUSOE_SECRET_KEY":   "sk-456",
		"CRUSOE_API_ENDPOINT": "https://api.crusoecloud.com/v1alpha5",
		"CRUSOE_PROJECT_ID":   "proj-789",
	}

	_, err := resolveCredentials(helperEnv(envs), "")
	if err == nil {
		t.Fatal("expected error for missing CRUSOE_ACCESS_KEY, got nil")
	}
	if !strings.Contains(err.Error(), "CRUSOE_ACCESS_KEY") {
		t.Errorf("error should mention CRUSOE_ACCESS_KEY, got: %v", err)
	}
}

func TestResolveCredentials_MissingSecretKey(t *testing.T) {
	envs := map[string]string{
		"CRUSOE_ACCESS_KEY":   "ak-123",
		"CRUSOE_API_ENDPOINT": "https://api.crusoecloud.com/v1alpha5",
		"CRUSOE_PROJECT_ID":   "proj-789",
	}

	_, err := resolveCredentials(helperEnv(envs), "")
	if err == nil {
		t.Fatal("expected error for missing CRUSOE_SECRET_KEY, got nil")
	}
	if !strings.Contains(err.Error(), "CRUSOE_SECRET_KEY") {
		t.Errorf("error should mention CRUSOE_SECRET_KEY, got: %v", err)
	}
}

func TestResolveCredentials_MissingProjectID(t *testing.T) {
	envs := map[string]string{
		"CRUSOE_ACCESS_KEY":   "ak-123",
		"CRUSOE_SECRET_KEY":   "sk-456",
		"CRUSOE_API_ENDPOINT": "https://api.crusoecloud.com/v1alpha5",
		// CRUSOE_PROJECT_ID not set, config also empty
	}

	_, err := resolveCredentials(helperEnv(envs), "")
	if err == nil {
		t.Fatal("expected error for missing project ID, got nil")
	}
	if !strings.Contains(err.Error(), "CRUSOE_PROJECT_ID") {
		t.Errorf("error should mention CRUSOE_PROJECT_ID, got: %v", err)
	}
}

func TestResolveCredentials_AllMissing(t *testing.T) {
	envs := map[string]string{}

	_, err := resolveCredentials(helperEnv(envs), "")
	if err == nil {
		t.Fatal("expected error when all credentials missing, got nil")
	}
}

func TestDirectEventRecorderCreateEvent(t *testing.T) {
	clientset := fake.NewSimpleClientset()
	recorder := &directEventRecorder{
		events:    clientset.CoreV1().Events("crusoe-node-remediation"),
		namespace: "crusoe-node-remediation",
	}

	node := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{
			Name: "node-1",
			UID:  "node-uid-123",
		},
	}

	recorder.Eventf(node, corev1.EventTypeNormal, "NodeRemediated", "node remediated with %s", "vm-reset")

	events, err := clientset.CoreV1().Events("crusoe-node-remediation").List(context.Background(), metav1.ListOptions{})
	if err != nil {
		t.Fatalf("failed to list events: %v", err)
	}

	if len(events.Items) != 1 {
		t.Fatalf("expected 1 event, got %d", len(events.Items))
	}

	event := events.Items[0]

	// Event should be in the recorder's namespace
	if event.Namespace != "crusoe-node-remediation" {
		t.Errorf("event namespace = %q, want %q", event.Namespace, "crusoe-node-remediation")
	}

	// InvolvedObject namespace must match event namespace (K8s requirement)
	if event.InvolvedObject.Namespace != event.Namespace {
		t.Errorf("InvolvedObject.Namespace = %q, want %q (must match event namespace)",
			event.InvolvedObject.Namespace, event.Namespace)
	}

	// InvolvedObject should reference the node
	if event.InvolvedObject.Kind != "Node" {
		t.Errorf("InvolvedObject.Kind = %q, want %q", event.InvolvedObject.Kind, "Node")
	}
	if event.InvolvedObject.Name != "node-1" {
		t.Errorf("InvolvedObject.Name = %q, want %q", event.InvolvedObject.Name, "node-1")
	}
	if event.InvolvedObject.UID != "node-uid-123" {
		t.Errorf("InvolvedObject.UID = %q, want %q", event.InvolvedObject.UID, "node-uid-123")
	}

	// Event should have the right reason and message
	if event.Reason != "NodeRemediated" {
		t.Errorf("Reason = %q, want %q", event.Reason, "NodeRemediated")
	}
	if event.Message != "node remediated with vm-reset" {
		t.Errorf("Message = %q, want %q", event.Message, "node remediated with vm-reset")
	}
	if event.Type != corev1.EventTypeNormal {
		t.Errorf("Type = %q, want %q", event.Type, corev1.EventTypeNormal)
	}
}

func TestDirectEventRecorderNilEvents(t *testing.T) {
	// Should not panic when events is nil
	recorder := &directEventRecorder{
		events:    nil,
		namespace: "test",
	}

	node := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: "node-1"},
	}

	// Should be a no-op, not a panic
	recorder.Eventf(node, corev1.EventTypeNormal, "Test", "test message")
}

func TestDirectEventRecorderNonNodeObject(t *testing.T) {
	clientset := fake.NewSimpleClientset()
	recorder := &directEventRecorder{
		events:    clientset.CoreV1().Events("test"),
		namespace: "test",
	}

	// Pass a non-Node object — should be silently ignored
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "pod-1", Namespace: "default"},
	}
	recorder.Eventf(pod, corev1.EventTypeNormal, "Test", "test message")

	events, _ := clientset.CoreV1().Events("test").List(context.Background(), metav1.ListOptions{})
	if len(events.Items) != 0 {
		t.Errorf("expected 0 events for non-Node object, got %d", len(events.Items))
	}
}
