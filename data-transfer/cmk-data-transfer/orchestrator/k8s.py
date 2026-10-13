"""Thin kubectl wrappers (shell out, stdlib only — mirrors the reference impl).

All cluster mutations funnel through here so they are easy to audit and so
--dry-run can intercept apply/run calls.
"""
from __future__ import annotations

import json
import subprocess
import sys
import time
from typing import Optional


class Kubectl:
    def __init__(self, namespace: str = "default", dry_run: bool = False):
        self.namespace = namespace
        self.dry_run = dry_run

    # ------------------------------------------------------------------ helpers
    def _base(self) -> list[str]:
        return ["kubectl", "-n", self.namespace]

    def _run(self, args: list[str], *, input_bytes: Optional[bytes] = None,
             check: bool = True, capture: bool = False) -> subprocess.CompletedProcess:
        cmd = self._base() + args
        return subprocess.run(
            cmd, input=input_bytes, check=check,
            capture_output=capture, text=False,
        )

    # ------------------------------------------------------------------ queries
    def get_json(self, *args: str) -> dict:
        proc = subprocess.run(
            self._base() + list(args) + ["-o", "json"],
            check=True, capture_output=True, text=True,
        )
        return json.loads(proc.stdout)

    def exists(self, kind: str, name: str) -> bool:
        proc = subprocess.run(
            self._base() + ["get", kind, name],
            capture_output=True, text=True,
        )
        return proc.returncode == 0

    def cluster_exists(self, kind: str, name: str) -> bool:
        """Cluster-scoped resources (e.g. storageclass, nodes)."""
        proc = subprocess.run(
            ["kubectl", "get", kind, name],
            capture_output=True, text=True,
        )
        return proc.returncode == 0

    def list_ready_nodes(self, instance_class: str) -> list[str]:
        data = self.get_json_cluster(
            "get", "nodes", "-l", f"crusoe.ai/instance.class={instance_class}",
        )
        names = []
        for n in data.get("items", []):
            conds = {c["type"]: c["status"] for c in
                     n.get("status", {}).get("conditions", [])}
            unschedulable = n.get("spec", {}).get("unschedulable", False)
            if conds.get("Ready") == "True" and not unschedulable:
                names.append(n["metadata"]["name"])
        return names

    def get_json_cluster(self, *args: str) -> dict:
        proc = subprocess.run(
            ["kubectl"] + list(args) + ["-o", "json"],
            check=True, capture_output=True, text=True,
        )
        return json.loads(proc.stdout)

    # ----------------------------------------------------------------- mutators
    def apply(self, manifest: dict) -> None:
        body = json.dumps(manifest).encode()
        if self.dry_run:
            kind = manifest.get("kind", "?")
            name = manifest.get("metadata", {}).get("name", "?")
            print(f"  [dry-run] would apply {kind}/{name}")
            return
        self._run(["apply", "-f", "-"], input_bytes=body)

    def apply_cluster(self, manifest: dict) -> None:
        """Apply a cluster-scoped resource (no namespace)."""
        body = json.dumps(manifest).encode()
        if self.dry_run:
            print(f"  [dry-run] would apply (cluster) "
                  f"{manifest.get('kind')}/{manifest['metadata']['name']}")
            return
        subprocess.run(["kubectl", "apply", "-f", "-"],
                       input=body, check=True)

    def create_secret_from_files(self, name: str,
                                 files: dict[str, str]) -> None:
        """Idempotent generic secret from in-memory file contents.

        Renders the secret as YAML via --dry-run=client then applies it, so the
        secret value never appears in a process arg list (avoids leaking creds
        into shell history / psaux). `files` maps filename -> contents.
        """
        if self.dry_run:
            print(f"  [dry-run] would create/replace secret/{name} "
                  f"with keys {list(files)}")
            return
        import base64
        manifest = {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {"name": name, "namespace": self.namespace},
            "type": "Opaque",
            "data": {
                k: base64.b64encode(v.encode()).decode()
                for k, v in files.items()
            },
        }
        self._run(["apply", "-f", "-"], input_bytes=json.dumps(manifest).encode())

    def wait_ready(self, pod: str, timeout: str = "600s") -> None:
        if self.dry_run:
            print(f"  [dry-run] would wait for pod/{pod} Ready")
            return
        self._run(["wait", "--for=condition=Ready", f"pod/{pod}",
                   f"--timeout={timeout}"])

    def exec(self, pod: str, argv: list[str], check: bool = True
             ) -> subprocess.CompletedProcess:
        if self.dry_run:
            print(f"  [dry-run] would exec in {pod}: {' '.join(argv)}")
            return subprocess.CompletedProcess(argv, 0, b"", b"")
        return self._run(["exec", pod, "--"] + argv, check=check,
                         capture=True)

    def cp_to(self, pod: str, local_path: str, remote_path: str) -> None:
        if self.dry_run:
            print(f"  [dry-run] would cp {local_path} -> {pod}:{remote_path}")
            return
        self._run(["cp", local_path, f"{pod}:{remote_path}"])

    def logs(self, pod: str, tail: int = 5) -> str:
        proc = self._run(["logs", "--tail", str(tail), pod],
                         check=False, capture=True)
        return proc.stdout.decode(errors="replace") if proc.stdout else ""

    def delete(self, kind: str, name: str = "", selector: str = "",
               wait: bool = False) -> None:
        if self.dry_run:
            tgt = name or f"-l {selector}"
            print(f"  [dry-run] would delete {kind} {tgt}")
            return
        args = ["delete", kind]
        if name:
            args.append(name)
        if selector:
            args += ["-l", selector]
        args += [f"--wait={'true' if wait else 'false'}", "--ignore-not-found"]
        self._run(args, check=False)


def die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)
