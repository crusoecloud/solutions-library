#!/bin/bash
# TDD Test: Helm template renders valid YAML
# Run: bash scripts/helm-template-test.sh

set -e

CHART_DIR="helm/crusoe-node-remediation"
FAIL=0

echo "=== Test 1: Default values render without error ==="
if helm template "$CHART_DIR" --set crusoeProjectId=test-project > /dev/null 2>&1; then
    echo "PASS"
else
    echo "FAIL: default values don't render"
    helm template "$CHART_DIR" --set crusoeProjectId=test-project 2>&1
    FAIL=1
fi

echo "=== Test 2: Dry-run mode renders ==="
if helm template "$CHART_DIR" --set crusoeProjectId=test-project --set dryRun=true > /dev/null 2>&1; then
    echo "PASS"
else
    echo "FAIL: dry-run mode doesn't render"
    FAIL=1
fi

echo "=== Test 3: Multi-step action renders ==="
if helm template "$CHART_DIR" --set crusoeProjectId=test-project \
  --set-json 'action.steps=[{"type":"vm-stop","timeout":"5m"},{"type":"vm-delete","timeout":"30m","wait":"2m"}]' \
  --set action.type="" > /dev/null 2>&1; then
    echo "PASS"
else
    echo "FAIL: multi-step action doesn't render"
    FAIL=1
fi

echo "=== Test 4: ClusterRole has nodes/proxy ==="
OUTPUT=$(helm template "$CHART_DIR" --set crusoeProjectId=test-project 2>&1)
if echo "$OUTPUT" | grep -q "nodes/proxy"; then
    echo "PASS"
else
    echo "FAIL: ClusterRole missing nodes/proxy"
    FAIL=1
fi

echo "=== Test 5: CronJob has concurrencyPolicy: Forbid ==="
if echo "$OUTPUT" | grep -q "concurrencyPolicy: Forbid"; then
    echo "PASS"
else
    echo "FAIL: CronJob missing concurrencyPolicy: Forbid"
    FAIL=1
fi

echo "=== Test 6: No Secret template rendered ==="
if echo "$OUTPUT" | grep -q "kind: Secret"; then
    echo "FAIL: Secret template should not be rendered"
    FAIL=1
else
    echo "PASS"
fi

echo "=== Test 7: Built-in secret mode references crusoe-secrets ==="
OUTPUT_BUILTIN=$(helm template "$CHART_DIR" --set crusoeProjectId=test-project 2>&1)
if echo "$OUTPUT_BUILTIN" | grep -q "name: crusoe-secrets"; then
    echo "PASS"
else
    echo "FAIL: built-in mode should reference crusoe-secrets"
    FAIL=1
fi

echo "=== Test 8: Built-in secret mode uses envFrom with crusoe-secrets ==="
if echo "$OUTPUT_BUILTIN" | grep -A2 'envFrom:' | grep -q 'name: crusoe-secrets'; then
    echo "PASS"
else
    echo "FAIL: built-in mode should use envFrom with crusoe-secrets"
    FAIL=1
fi

echo "=== Test 9: Custom secret mode references crusoe-api-credentials ==="
OUTPUT_CUSTOM=$(helm template "$CHART_DIR" --set crusoeProjectId=test-project --set useBuiltinSecret=false --set crusoeApiSecret=crusoe-api-credentials 2>&1)
if echo "$OUTPUT_CUSTOM" | grep -q "name: crusoe-api-credentials"; then
    echo "PASS"
else
    echo "FAIL: custom mode should reference crusoe-api-credentials"
    FAIL=1
fi

echo "=== Test 10: Custom secret mode does NOT have envFrom ==="
if echo "$OUTPUT_CUSTOM" | grep -q 'envFrom:'; then
    echo "FAIL: custom mode should not use envFrom"
    FAIL=1
else
    echo "PASS"
fi

echo "=== Test 11: Built-in mode does NOT have explicit secretKeyRef entries ==="
if echo "$OUTPUT_BUILTIN" | grep -q 'secretKeyRef:'; then
    echo "FAIL: built-in mode should use envFrom, not explicit secretKeyRef"
    FAIL=1
else
    echo "PASS"
fi

echo "=== Test 12: Custom mode uses CRUSOE_API_ENDPOINT env var name ==="
if echo "$OUTPUT_CUSTOM" | grep -q "name: CRUSOE_API_ENDPOINT"; then
    echo "PASS"
else
    echo "FAIL: custom mode should use CRUSOE_API_ENDPOINT env var"
    FAIL=1
fi

echo "=== Test 13: Security context present ==="
if echo "$OUTPUT" | grep -q "runAsNonRoot: true"; then
    echo "PASS"
else
    echo "FAIL: securityContext missing"
    FAIL=1
fi

if [ $FAIL -eq 0 ]; then
    echo ""
    echo "All Helm template tests PASSED"
    exit 0
else
    echo ""
    echo "Some Helm template tests FAILED"
    exit 1
fi
