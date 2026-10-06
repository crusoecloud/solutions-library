# Gateway load test

Drives high concurrent load at a KServe/vLLM deployment's **Envoy gateway VIP** to
find the throughput ceiling and size node count vs. concurrent users. Run from a
**separate cluster** (ideally a different region) so you exercise the real
client → LB → gateway → EPP → replica path, not just in-cluster localhost.

Each load-gen pod holds **persistent keep-alive connections** and fires OpenAI
chat-completions back-to-back (`min_tokens`+`ignore_eos` force a fixed output
length so throughput is comparable run-to-run). The client leg stays keep-alive —
a pod never churns ephemeral ports — while the L7 gateway still load-balances every
*request* across all upstream replicas. Scale total offered load by **pod count**,
not by hammering one pod until its sockets exhaust.

## Two harnesses

| File | Model | Per-pod density | Use for |
|------|-------|-----------------|---------|
| `loadgen.py` | threaded (one thread/conn) | ~hundreds | Standard runs; wired into the Makefile |
| `loadgen_async.py` | asyncio (one task/conn) | ~thousands | Extreme concurrency to stress the gateway |

Both are pure stdlib (run on any `python:3.x` image), emit a heartbeat plus a final
`RESULT_JSON {...}` line, and always exit 0 so the Job completes and logs stay
collectible. The async harness needs the container fd limit raised above the
per-pod concurrency — its Job (`gateway-stress-job.yaml`) does `ulimit -n` and adds
the `SYS_RESOURCE` capability.

## Quick start (threaded, via Makefile)

```bash
# On the SERVING cluster — get the gateway VIP:
kubectl get gateway kserve-ingress-gateway -n kserve -o jsonpath='{.status.addresses[0].value}'

# On a SEPARATE cluster (set KUBECONFIG/context to it):
make loadtest-distributed \
  LOADTEST_TARGET_URL=http://<VIP>/<namespace>/<isvc> \
  LOADTEST_PODS=25 LOADTEST_CONCURRENCY=256 LOADTEST_DURATION=120
# total offered concurrency = PODS * CONCURRENCY

make loadtest-report    # aggregate throughput / success / fail / TTFT across pods
make loadtest-clean     # tear down the Job + namespace
```

Pin load-gen off serving/gateway nodes with `LOADTEST_NODE_SELECTOR='node.kubernetes.io/instance-type: <cpu-type>'`.
The `TARGET_URL` path is the gateway route prefix for the ISVC (`/<namespace>/<isvc>`);
`served-model-name` must match what `/v1/models` reports or requests 404.

## Async harness (high density)

`gateway-stress-job.yaml` is an Indexed Job templated with `envsubst` (vars:
`REGION PODS CONCURRENCY DURATION RAMP_SECONDS OUTPUT_LEN TARGET_URL NODE_SELECTOR CPU_REQ MEM_REQ MEM_LIM`).
It mounts `loadgen_async.py` from a `loadgen-async` ConfigMap. Keep per-node
connection density modest (≤ ~2–3k conn/node) — beyond that, network-softirq /
kubelet starvation flips load-gen nodes `NotReady` before the gateway is stressed;
add pods/nodes to go higher.

## Notes

- **Open vs closed loop:** these harnesses are closed-loop — exactly `CONCURRENCY`
  requests outstanding per pod (a fixed number of simulated users), so throughput
  reflects sustainable capacity rather than an unbounded arrival rate.
- The gateway itself is rarely the ceiling — with a scaled Envoy tier
  (`make install-gateway-scaling`), the load generator's CPU/connection budget
  usually tips first. Watch `downstream_cx_active` / 5xx on Envoy and
  `num_requests_running` on the replicas to identify the binding layer.
