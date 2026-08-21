package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	v1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes"
	typedcorev1 "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"

	"crusoe-node-remediation/internal/actions"
	"crusoe-node-remediation/internal/config"
	"crusoe-node-remediation/internal/crusoe"
	"crusoe-node-remediation/internal/discovery"
	"crusoe-node-remediation/internal/guardrails"
	"crusoe-node-remediation/internal/k8s"
	"crusoe-node-remediation/internal/logging"
	"crusoe-node-remediation/internal/remediation"

	"k8s.io/client-go/dynamic"
)

func resolveProjectID(envValue, configValue string) string {
	if envValue != "" {
		return envValue
	}
	return configValue
}

// CrusoeCredentials holds the resolved API credentials for the Crusoe client.
type CrusoeCredentials struct {
	AccessKey string
	SecretKey string
	APIURL    string
	ProjectID string
}

// BuiltinSecretPath is the mount path for the projected crusoe-secrets volume.
// Declared as a var (not const) so tests can override it.
var BuiltinSecretPath = "/etc/crusoe-secrets"

// lookupCredential checks an env var first, then falls back to reading a file
// at BuiltinSecretPath/<envKey>. This supports two credential modes:
//   - Custom secret: env vars set via secretKeyRef (file path doesn't exist)
//   - Built-in secret: files mounted via projected volume (env vars not set)
func lookupCredential(env func(string) string, envKey string) string {
	if v := env(envKey); v != "" {
		return v
	}
	filePath := filepath.Join(BuiltinSecretPath, envKey)
	data, err := os.ReadFile(filePath)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// resolveCredentials builds CrusoeCredentials from environment variables, mounted
// secret files, and config. This is the shared logic for both credential modes:
//   - Built-in secret mode: crusoe-secrets mounted as a projected volume at
//     /etc/crusoe-secrets (cross-namespace from crusoe-system)
//   - Custom secret mode: env vars set via secretKeyRef from a same-namespace secret
//
// Resolution rules (env var takes priority over file):
//   - AccessKey: from CRUSOE_ACCESS_KEY env var or file (required)
//   - SecretKey: from CRUSOE_SECRET_KEY env var or file (required)
//   - APIURL: from CRUSOE_API_ENDPOINT env var or file, falls back to default if empty
//   - ProjectID: from CRUSOE_PROJECT_ID env var or file, falls back to config value
//
// Returns an error if required fields are missing.
func resolveCredentials(env func(string) string, configProjectID string) (CrusoeCredentials, error) {
	accessKey := lookupCredential(env, "CRUSOE_ACCESS_KEY")
	secretKey := lookupCredential(env, "CRUSOE_SECRET_KEY")
	apiURL := lookupCredential(env, "CRUSOE_API_ENDPOINT")
	projectID := resolveProjectID(lookupCredential(env, "CRUSOE_PROJECT_ID"), configProjectID)

	if accessKey == "" {
		return CrusoeCredentials{}, fmt.Errorf("CRUSOE_ACCESS_KEY must be set")
	}
	if secretKey == "" {
		return CrusoeCredentials{}, fmt.Errorf("CRUSOE_SECRET_KEY must be set")
	}
	if apiURL == "" {
		apiURL = "https://api.cloud.crusoe.ai/v1alpha5"
	}
	if projectID == "" {
		return CrusoeCredentials{}, fmt.Errorf("CRUSOE_PROJECT_ID env var or crusoeProjectId config must be set")
	}

	return CrusoeCredentials{
		AccessKey: accessKey,
		SecretKey: secretKey,
		APIURL:    apiURL,
		ProjectID: projectID,
	}, nil
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)

	// Dual logging: write to both stdout (kubectl logs) and journald
	// (Crusoe Managed Logs console). Journald is only enabled when the
	// JOURNALD_LOGGING env var is set to "true" and the socket is
	// available; otherwise stdout-only (no behaviour change).
	if os.Getenv("JOURNALD_LOGGING") == "true" {
		jw := logging.NewJournalWriter("crusoe-node-remediation")
		log.SetOutput(io.MultiWriter(os.Stdout, jw))
	}

	// --validate: load and validate config, then exit (for e2e/CI)
	validateOnly := flag.Bool("validate", false, "validate config and exit")
	// --verify-api: verify Crusoe API access and exit
	verifyAPIOnly := flag.Bool("verify-api", false, "verify Crusoe API access and exit")
	flag.Parse()

	log.Println("crusoe-node-remediation starting")
	log.Println("────────────────────────────────────────────────────────────")

	// 1. Load config from mounted ConfigMap
	configPath := os.Getenv("CONFIG_PATH")
	if configPath == "" {
		configPath = "/etc/crusoe-node-remediation/config.yaml"
	}

	configData, err := os.ReadFile(configPath)
	if err != nil {
		log.Fatalf("failed to read config file %s: %v", configPath, err)
	}

	cfg, err := config.LoadFromYAML(configData)
	if err != nil {
		log.Fatalf("failed to load config: %v", err)
	}

	if err := cfg.Validate(); err != nil {
		log.Fatalf("config validation failed: %v", err)
	}

	log.Printf("config: thresholds=(cordon=%s, remediation=%s, cooldown=%s), action=(type=%s, dryRun=%v), guardrails=(global=%d, perPool=%d), drain=(timeout=%s, force=%v)",
		cfg.CordonDuration(), cfg.RemediationThresholdDuration(), cfg.RemediationCooldownDuration(),
		cfg.Action.Type, cfg.DryRun,
		cfg.Guardrails.GlobalMaxCordoned, cfg.Guardrails.PerPoolMaxCordoned,
		cfg.DrainTimeout, cfg.ForceAfterEvictionFailure)

	// If --validate, exit here (config is valid)
	if *validateOnly {
		log.Println("config validation passed")
		os.Exit(0)
	}

	// 2. Load Crusoe API credentials from environment (populated by secretKeyRef)
	creds, err := resolveCredentials(os.Getenv, cfg.CrusoeProjectID)
	if err != nil {
		log.Fatalf("credential error: %v", err)
	}

	// 3. Create K8s client
	k8sClientset, restConfig, err := createK8sClient()
	if err != nil {
		log.Fatalf("failed to create K8s client: %v", err)
	}

	k8sClient := k8s.NewClient(k8sClientset, nil)

	// 3a. Create dynamic client for CRD operations
	dynamicClient, err := dynamic.NewForConfig(restConfig)
	if err != nil {
		log.Fatalf("failed to create dynamic client: %v", err)
	}

	// 4. Create Crusoe API client (HMAC auth with access/secret key pair)
	crusoeClient := crusoe.NewClient(creds.APIURL, creds.AccessKey, creds.SecretKey, creds.ProjectID)

	// 4a. Verify Crusoe API access — fail fast if credentials are invalid
	log.Println("verifying Crusoe API access...")
	if err := crusoeClient.VerifyAccess(context.Background()); err != nil {
		log.Fatalf("%v", err)
	}

	// If --verify-api, exit here (API access verified)
	if *verifyAPIOnly {
		os.Exit(0)
	}

	// 5. Create step factory
	stepFactory := actions.NewFactory(k8sClient, crusoeClient)

	// 6. Create drain manager
	drainMgr := k8s.NewDrainManager(k8sClient, k8sClientset, cfg.DrainTimeout, cfg.ForceAfterEvictionFailure)

	// 7. Create guardrail checker
	guardChecker := guardrails.NewChecker(cfg.Guardrails)

	// 8. Create discoverer
	discoverer := discovery.NewDiscoverer(k8sClient, cfg)

	// 9. Create K8s Event recorder
	// Use direct API event creation instead of the broadcaster to prevent
	// event dropping when multiple nodes are remediated in quick succession.
	// Events are recorded in the pod's namespace (via POD_NAMESPACE env var)
	// so they appear alongside the CronJob, not in the default namespace.
	eventNamespace := os.Getenv("POD_NAMESPACE")
	if eventNamespace == "" {
		eventNamespace = "default"
	}
	recorder := &directEventRecorder{
		events:    k8sClientset.CoreV1().Events(eventNamespace),
		namespace: eventNamespace,
	}

	// 9a. Create ReportWriter for progressive CRD updates
	reportWriter := remediation.NewReportWriter(dynamicClient, eventNamespace)

	// 10. Create uptime evaluator (uses K8s client for stats summary)
	uptimeEval := &k8sUptimeEvaluator{k8sClient: k8sClient}

	// 11. Create remediation manager
	deps := remediation.Dependencies{
		K8sClient:    k8sClient,
		DrainMgr:     drainMgr,
		StepFactory:  stepFactory,
		UptimeEval:   uptimeEval,
		GuardChecker: guardChecker,
		Discoverer:   discoverer,
		Config:       cfg,
		Recorder:     recorder,
		ReportWriter: reportWriter,
	}

	mgr := remediation.NewManager(deps)

	// 12. Run one pass (CronJob triggers a new pod each run)
	ctx, cancel := context.WithTimeout(context.Background(), time.Hour)
	defer cancel()

	if _, err := mgr.Run(ctx); err != nil {
		log.Printf("remediation run failed: %v", err)
		os.Exit(1)
	}

	log.Println("────────────────────────────────────────────────────────────")
	log.Println("crusoe-node-remediation completed successfully")
}

// k8sUptimeEvaluator implements remediation.UptimeEvaluator using the K8s client.
type k8sUptimeEvaluator struct {
	k8sClient *k8s.Client
}

func (e *k8sUptimeEvaluator) GetNodeStartTime(ctx context.Context, nodeName string) (time.Time, error) {
	return e.k8sClient.GetNodeStartTime(ctx, nodeName)
}

// directEventRecorder creates K8s events directly via the API instead of
// using the broadcaster, which can drop events when multiple nodes are
// remediated in quick succession.
type directEventRecorder struct {
	events    typedcorev1.EventInterface
	namespace string
}

func (r *directEventRecorder) Event(obj runtime.Object, eventType, reason, message string) {
	r.createEvent(obj, eventType, reason, message)
}

func (r *directEventRecorder) Eventf(obj runtime.Object, eventType, reason, messageFmt string, args ...interface{}) {
	r.createEvent(obj, eventType, reason, fmt.Sprintf(messageFmt, args...))
}

func (r *directEventRecorder) AnnotatedEventf(obj runtime.Object, annotations map[string]string, eventType, reason, messageFmt string, args ...interface{}) {
	r.Eventf(obj, eventType, reason, messageFmt, args...)
}

func (r *directEventRecorder) createEvent(obj runtime.Object, eventType, reason, message string) {
	if r.events == nil {
		return
	}
	node, ok := obj.(*corev1.Node)
	if !ok {
		return
	}
	now := v1.Now()
	_, err := r.events.Create(context.Background(), &corev1.Event{
		ObjectMeta: v1.ObjectMeta{
			GenerateName: "crusoe-node-remediation-",
			Namespace:    r.namespace,
		},
		InvolvedObject: corev1.ObjectReference{
			Kind:       "Node",
			Name:       node.Name,
			UID:        node.UID,
			APIVersion: "v1",
			Namespace:  r.namespace,
		},
		Reason:  reason,
		Message: message,
		Source: corev1.EventSource{
			Component: "crusoe-node-remediation",
		},
		FirstTimestamp: now,
		LastTimestamp:  now,
		Count:          1,
		Type:           eventType,
	}, v1.CreateOptions{})
	if err != nil {
		log.Printf("warning: failed to create event (reason=%s, node=%s): %v", reason, node.Name, err)
	}
}

func createK8sClient() (*kubernetes.Clientset, *rest.Config, error) {
	// Try in-cluster config first
	config, err := rest.InClusterConfig()
	if err == nil {
		clientset, err := kubernetes.NewForConfig(config)
		if err != nil {
			return nil, nil, err
		}
		return clientset, config, nil
	}

	// Fall back to kubeconfig
	home := os.Getenv("HOME")
	if home == "" {
		home = "/root"
	}
	kubeconfigPath := filepath.Join(home, ".kube", "config")

	config, err = clientcmd.BuildConfigFromFlags("", kubeconfigPath)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to create K8s config: %w", err)
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, nil, err
	}
	return clientset, config, nil
}
