import base64, json, os, pathlib, sys, time, urllib.request, urllib.error

env = {}
for line in pathlib.Path("env").read_text().splitlines():
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip()

token = env.get("CRUSOE_MONITORING_TOKEN", "")
project_id = env.get("CRUSOE_PROJECT_ID", "")
if not token or not project_id:
    sys.exit("ERROR: CRUSOE_MONITORING_TOKEN and CRUSOE_PROJECT_ID must be set in monitoring/env")

auth = base64.b64encode(b"admin:admin").decode()
headers = {"Content-Type": "application/json", "Authorization": f"Basic {auth}"}

def api(method, path, body=None):
    req = urllib.request.Request(
        f"http://localhost:3000{path}",
        data=json.dumps(body).encode() if body else None,
        headers=headers,
        method=method,
    )
    try:
        return json.loads(urllib.request.urlopen(req).read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read())

print("Waiting for Grafana...")
for _ in range(60):
    try:
        urllib.request.urlopen("http://localhost:3000/api/health", timeout=2)
        break
    except Exception:
        time.sleep(1)
else:
    sys.exit("ERROR: Grafana did not start within 60s")

print("Configuring datasource...")
ds = {
    "name": "Crusoe",
    "type": "prometheus",
    "uid": "prometheus",
    "url": f"https://api.crusoecloud.com/v1alpha5/projects/{project_id}/metrics/timeseries",
    "access": "proxy",
    "isDefault": True,
    "jsonData": {"httpMethod": "GET", "httpHeaderName1": "Authorization"},
    "secureJsonData": {"httpHeaderValue1": f"Bearer {token}"},
}
result = api("POST", "/api/datasources", ds)
if "already exists" in result.get("message", ""):
    ds_id = api("GET", "/api/datasources/name/Crusoe")["id"]
    result = api("PUT", f"/api/datasources/{ds_id}", ds)
print(" ", result.get("message", result))

cluster = os.environ.get("CLUSTER", "nvidia")
dashboard_uid = "amd-gpu-inference" if cluster == "amd" else "gpu-inference"
print("\nDone!")
print(f"Dashboard: http://localhost:3000/d/{dashboard_uid}  (admin / admin)")
