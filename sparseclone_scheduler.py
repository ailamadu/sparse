#!/usr/bin/env python3
"""
sparseclone_scheduler.py  — SparseClone Scheduler Daemon
===========================================================
Zero external dependencies — Python 3.6+ stdlib only.

Replaces apscheduler  →  background thread + time.sleep() cron loop
Replaces paramiko     →  subprocess calling system ssh binary

Usage:
  python3 sparseclone_scheduler.py
  python3 sparseclone_scheduler.py --port 7891 --data-dir /opt/sparseclone/data

API endpoints (proxied through sparseclone_manager.js on port 7890):
  GET  /api/schedules
  POST /api/schedules/save       { schedules: [...] }
  POST /api/schedules/delete     { id: <int> }
  GET  /api/scheduler/status
  POST /api/scheduler/run-now    { id: <int> }
  GET  /api/scheduler/logs?id=<int>&n=200
  GET  /api/ssh/settings
  POST /api/ssh/save
"""

import argparse
import json
import logging
import os
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional

# ── logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("sparseclone.scheduler")

# ── args ──────────────────────────────────────────────────────────────────────
parser = argparse.ArgumentParser(description="SparseClone Scheduler Daemon (stdlib only)")
parser.add_argument("--port",     type=int, default=7891)
parser.add_argument("--host",     default="0.0.0.0")
parser.add_argument("--data-dir", default=None)
args = parser.parse_args()

DATA_DIR       = Path(args.data_dir) if args.data_dir else Path(__file__).parent
SCHEDULES_FILE = DATA_DIR / "sparseclone_schedules.json"
SSH_FILE       = DATA_DIR / "sparseclone_ssh.json"
LOG_DIR        = DATA_DIR / "logs"
DATA_DIR.mkdir(parents=True, exist_ok=True)
LOG_DIR.mkdir(parents=True, exist_ok=True)

MAX_RUNS_PER_SCHEDULE = 20
MAX_LOG_LINES         = 2000

_run_registry: Dict[int, List[Dict]] = {}
_registry_lock = threading.Lock()


# ─────────────────────────────────────────────────────────────────────────────
# JSON helpers
# ─────────────────────────────────────────────────────────────────────────────

def _read_json(path: Path, default):
    try:
        if path.exists():
            return json.loads(path.read_text())
    except Exception as e:
        log.warning("Could not read %s: %s", path, e)
    return default

def _write_json(path: Path, data):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2))
    tmp.replace(path)

def read_schedules() -> List[Dict]:
    d = _read_json(SCHEDULES_FILE, [])
    return d if isinstance(d, list) else []

def write_schedules(s: List[Dict]):
    _write_json(SCHEDULES_FILE, s)

def read_ssh() -> Dict:
    return _read_json(SSH_FILE, {})

def write_ssh(s: Dict):
    _write_json(SSH_FILE, s)


# ─────────────────────────────────────────────────────────────────────────────
# Cron matching — pure stdlib
# ─────────────────────────────────────────────────────────────────────────────

def _field_matches(expr: str, value: int) -> bool:
    expr = (expr or "*").strip()
    if expr == "*":
        return True
    for part in expr.split(","):
        part = part.strip()
        if "/" in part:
            range_part, step_str = part.split("/", 1)
            step = int(step_str)
            if range_part == "*":
                start, end = 0, 59
            elif "-" in range_part:
                s, e = range_part.split("-", 1)
                start, end = int(s), int(e)
            else:
                start = int(range_part); end = 59
            if start <= value <= end and (value - start) % step == 0:
                return True
        elif "-" in part:
            s, e = part.split("-", 1)
            if int(s) <= value <= int(e):
                return True
        else:
            try:
                if int(part) == value:
                    return True
            except ValueError:
                pass
    return False

def _cron_dow(cron: Dict, dt: datetime) -> bool:
    """Match day-of-week: cron uses 0=Sun..6=Sat; Python weekday 0=Mon..6=Sun."""
    expr = str(cron.get("dow", "*") or "*")
    if expr == "*":
        return True
    py_dow = dt.weekday()                # Mon=0
    cron_dow = (py_dow + 1) % 7         # Sun=0
    return _field_matches(expr, cron_dow)

def cron_matches(cron: Dict, dt: datetime) -> bool:
    return (
        _field_matches(str(cron.get("min",   "*") or "*"), dt.minute) and
        _field_matches(str(cron.get("hour",  "*") or "*"), dt.hour)   and
        _field_matches(str(cron.get("dom",   "*") or "*"), dt.day)    and
        _field_matches(str(cron.get("month", "*") or "*"), dt.month)  and
        _cron_dow(cron, dt)
    )

def next_run_iso(cron: Dict) -> Optional[str]:
    now = datetime.now(timezone.utc).replace(second=0, microsecond=0)
    for _ in range(525600):
        now = now + timedelta(minutes=1)
        if cron_matches(cron, now):
            return now.isoformat()
    return None


# ─────────────────────────────────────────────────────────────────────────────
# SSH execution via system ssh binary — no paramiko needed
# ─────────────────────────────────────────────────────────────────────────────

def _build_ssh_argv(ssh: Dict, remote_cmd: str, interactive: bool = True) -> List[str]:
    argv = [
        "ssh",
        "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=15",
        "-o", "BatchMode=yes",
        "-o", "LogLevel=ERROR",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3",
    ]
    if interactive:
        argv.append("-tt")
    key = (ssh.get("sshKey") or "").strip()
    if key:
        argv += ["-i", key]
    port = ssh.get("sshPort")
    if port and int(port) != 22:
        argv += ["-p", str(port)]
    user = ssh.get("sshUser") or "oracle"
    host = ssh.get("sshHost") or ""
    argv.append(f"{user}@{host}")
    argv.append(remote_cmd)
    return argv

def _build_remote_cmd(sched: Dict, ssh: Dict) -> str:
    # run_sparseclone.sh handles SSH to target internally.
    # It strips --config and uses its baked REMOTE_CONFIG (scriptDir/sparse_clone.conf).
    # We do NOT pass confFile here — it is a Docker-internal path and would appear
    # misleadingly in logs. The correct remote conf path is baked into run_sparseclone.sh
    # at generation time as REMOTE_CONFIG = scriptDir/sparse_clone.conf.
    script_dir  = (ssh.get("scriptDir") or "").rstrip("/")
    script_name = "run_sparseclone.sh"
    if script_dir:
        cmd = f'cd "{script_dir}" && /bin/bash "{script_dir}/{script_name}"'
    else:
        cmd = f'/bin/bash "./{script_name}"'
    if sched.get("type") == "refresh":
        cmd += " --refresh"
    return cmd



def _build_scp_argv(ssh, local_path, remote_path):
    # Build scp argv to copy a local file to the remote host.
    argv = ["scp", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=15", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR"]
    key = (ssh.get("sshKey") or "").strip()
    if key:
        argv += ["-i", key]
    port = ssh.get("sshPort")
    if port and int(port) != 22:
        argv += ["-P", str(port)]
    user = ssh.get("sshUser") or "oracle"
    host = ssh.get("sshHost") or ""
    argv.append(local_path)
    argv.append(f"{user}@{host}:{remote_path}")
    return argv


def _deploy_files(sched, ssh, push):
    # Deploy scripts and conf file to remote before execution.
    # Uses ONE ssh call for all mkdir ops, then individual scp calls.
    # script_dir comes from ssh.scriptDir (the real remote path).
    # confFile is a Docker-internal path passed as --config arg only — never used as a remote deploy path.
    script_dir  = (ssh.get("scriptDir") or "").rstrip("/")
    conf_remote = (sched.get("confFile") or "").strip()
    user        = ssh.get("sshUser") or "oracle"
    host        = ssh.get("sshHost") or ""


    # Build list of remote dirs to create in one SSH call.
    # Only script_dir is a real remote path; conf_remote is Docker-internal so excluded.
    dirs_to_make = [script_dir] if script_dir else []

    if dirs_to_make:
        mkdir_cmd = "mkdir -p " + " ".join('"' + d + '"' for d in dirs_to_make)
        push(f"[DEPLOY] Creating remote dirs: {dirs_to_make}")
        try:
            subprocess.run(
                _build_ssh_argv(ssh, mkdir_cmd, interactive=False),
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        except Exception as e:
            push(f"[WARN] mkdir: {e}")

    def _scp_file(local_path, remote_path, fatal=True, strip_crlf=False):
        """SCP a local file to remote. If strip_crlf, write a clean LF-only
        temp copy first (fixes Windows-edited shell scripts). Returns True on success."""
        import tempfile
        src = local_path
        tmp = None
        if strip_crlf:
            try:
                content = open(local_path, 'rb').read().replace(b'\r\n', b'\n').replace(b'\r', b'\n')
                tmp = tempfile.NamedTemporaryFile(delete=False, suffix=Path(local_path).suffix)
                tmp.write(content)
                tmp.close()
                src = tmp.name
            except Exception as e:
                push(f"[WARN] CRLF strip failed for {Path(local_path).name}: {e}")
        try:
            r = subprocess.run(
                _build_scp_argv(ssh, src, remote_path),
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
            ok = r.returncode == 0
        except subprocess.TimeoutExpired:
            push(f"[{'ERROR' if fatal else 'WARN'}] SCP {Path(local_path).name} timed out")
            return False
        except Exception as e:
            push(f"[{'ERROR' if fatal else 'WARN'}] SCP {Path(local_path).name}: {e}")
            return False
        finally:
            if tmp:
                try: os.unlink(tmp.name)
                except Exception: pass
        return ok

    # SCP run_sparseclone.sh  (strip CRLF — shell script)
    script_name  = "run_sparseclone.sh"
    local_script = next((str(c) for c in [DATA_DIR / script_name, Path(__file__).parent / script_name] if c.exists()), None)
    if local_script and script_dir:
        remote_script = script_dir + "/" + script_name
        push(f"[DEPLOY] SCP {script_name} -> {user}@{host}:{remote_script}")
        if _scp_file(local_script, remote_script, fatal=True, strip_crlf=True):
            push(f"[DEPLOY] {script_name} transferred OK")
        else:
            push(f"[ERROR] SCP {script_name} failed")
            return False
    elif not local_script:
        push(f"[WARN] {script_name} not found locally in {DATA_DIR} -- skipping")

    # SCP exadata_sparseclone_create_v6.sh  (strip CRLF — shell script)
    exadata_script_name = "exadata_sparseclone_create_v6.sh"
    local_exadata = next((str(c) for c in [DATA_DIR / exadata_script_name, Path(__file__).parent / exadata_script_name] if c.exists()), None)
    if local_exadata and script_dir:
        remote_exadata = script_dir + "/" + exadata_script_name
        push(f"[DEPLOY] SCP {exadata_script_name} -> {user}@{host}:{remote_exadata}")
        if _scp_file(local_exadata, remote_exadata, fatal=True, strip_crlf=True):
            push(f"[DEPLOY] {exadata_script_name} transferred OK")
        else:
            push(f"[ERROR] SCP {exadata_script_name} failed")
            return False
    elif not local_exadata:
        push(f"[WARN] {exadata_script_name} not found locally in {DATA_DIR} -- skipping")

    # SCP the profile-specific conf file → remote scriptDir/sparse_clone.conf
    # Use sched["confFile"] (the profile path set in the UI) as the local source.
    # This ensures the correct profile conf is deployed, not whatever file happened
    # to be last written to DATA_DIR/sparse_clone.conf (which caused the wrong
    # profile — e.g. RIB — to be used even when Default was selected).
    sparse_conf_name = "sparse_clone.conf"
    conf_source = (sched.get("confFile") or "").strip()
    if not conf_source:
        # Fallback: look for the generic sparse_clone.conf in DATA_DIR
        fallback = next(
            (str(c) for c in [DATA_DIR / sparse_conf_name, Path(__file__).parent / sparse_conf_name]
             if c.exists()), None)
        if fallback:
            push(f"[WARN] No confFile set on schedule — falling back to {fallback}")
        conf_source = fallback

    if conf_source and script_dir:
        remote_sparse_conf = script_dir + "/" + sparse_conf_name
        push(f"[DEPLOY] SCP {Path(conf_source).name} -> {user}@{host}:{remote_sparse_conf}")
        if _scp_file(conf_source, remote_sparse_conf, fatal=False):
            push(f"[DEPLOY] conf transferred OK  (source: {Path(conf_source).name})")
        else:
            push(f"[WARN] SCP conf failed -- using existing conf on target")
    elif not conf_source:
        push(f"[INFO] No conf file found locally -- using existing conf on target")

    return True


def run_via_ssh(sched: Dict, ssh: Dict, run_record: Dict):
    def push(line: str):
        run_record["log"].append(line)
        if len(run_record["log"]) > MAX_LOG_LINES:
            run_record["log"] = run_record["log"][-MAX_LOG_LINES:]
        try:
            with open(run_record["logFile"], "a") as f:
                f.write(line + "\n")
        except Exception:
            pass

    host = ssh.get("sshHost", "")
    user = ssh.get("sshUser", "oracle")

    push(f"[{datetime.now(timezone.utc).isoformat()}] Starting '{sched.get('name')}' "
         f"(id={sched['id']}, type={sched.get('type','create')})")
    push(f"[INFO] SSH target: {user}@{host}")

    if not host:
        push("[ERROR] SSH host not configured — aborting")
        run_record.update(status="failed", exitCode=-1,
                          finishedAt=datetime.now(timezone.utc).isoformat())
        return

    # Deploy scripts and conf to remote before executing
    if not _deploy_files(sched, ssh, push):
        run_record.update(status="failed", exitCode=-1,
                          finishedAt=datetime.now(timezone.utc).isoformat())
        return

    remote_cmd = _build_remote_cmd(sched, ssh)
    argv       = _build_ssh_argv(ssh, remote_cmd, interactive=False)
    push(f"[CMD] {' '.join(argv)}")
    push(f"[INFO] Launching SSH process...")

    try:
        proc = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=1,
            universal_newlines=True,
        )
        push(f"[INFO] SSH process started (pid={proc.pid}), waiting for output...")
        run_record["status"] = "running"
        for line in proc.stdout:
            push(line.rstrip("\r\n"))
        proc.wait()
        exit_code = proc.returncode
        run_record["exitCode"]   = exit_code
        run_record["status"]     = "success" if exit_code == 0 else "failed"
        run_record["finishedAt"] = datetime.now(timezone.utc).isoformat()
        push(f"[{run_record['finishedAt']}] Exit {exit_code} — "
             f"{'SUCCESS' if exit_code == 0 else 'FAILED'}")
    except Exception as e:
        push(f"[ERROR] {e}")
        run_record.update(status="failed", exitCode=-1,
                          finishedAt=datetime.now(timezone.utc).isoformat())


# ─────────────────────────────────────────────────────────────────────────────
# Cron scheduler loop
# ─────────────────────────────────────────────────────────────────────────────

_fired: Dict[str, str] = {}
_fired_lock = threading.Lock()

def _safe_name(name: str) -> str:
    """Sanitise a schedule name for use as a filename."""
    import re
    safe = re.sub(r'[^\w\-]', '_', name.strip())
    safe = re.sub(r'_+', '_', safe).strip('_')
    return safe[:60] if safe else 'schedule'


def _execute_schedule(sched_id: int, triggered_by: str = "scheduler", sched_override: Dict = None):
    # If a patched schedule dict was passed (e.g. with confFile/scriptDir overrides
    # from a manual Run Now request), use it directly instead of re-reading from disk.
    if sched_override is not None:
        sched = sched_override
    else:
        schedules = read_schedules()
        sched = next((s for s in schedules if s["id"] == sched_id), None)
    if not sched:
        log.warning("[SCHED] id=%s not found", sched_id)
        return

    ssh = read_ssh()
    ts  = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    run_record: Dict = {
        "scheduleId":  sched_id,
        "startedAt":   datetime.now(timezone.utc).isoformat(),
        "finishedAt":  None,
        "status":      "starting",
        "exitCode":    None,
        "log":         [],
        "logFile":     str(LOG_DIR / f"{_safe_name(sched.get('name','schedule'))}_{ts}.log"),
        "triggeredBy": triggered_by,
    }
    with _registry_lock:
        _run_registry.setdefault(sched_id, []).insert(0, run_record)
        _run_registry[sched_id] = _run_registry[sched_id][:MAX_RUNS_PER_SCHEDULE]

    log.info("[SCHED] Firing '%s' (id=%s, by=%s) → %s@%s",
             sched.get("name"), sched_id, triggered_by,
             ssh.get("sshUser","?"), ssh.get("sshHost","?"))

    threading.Thread(
        target=run_via_ssh, args=(sched, ssh, run_record),
        daemon=True, name=f"run-{sched_id}-{ts}"
    ).start()

def _scheduler_loop():
    log.info("[SCHED] Cron loop started (ticks every 30 s)")
    while True:
        try:
            now     = datetime.now(timezone.utc)
            now_min = now.strftime("%Y-%m-%dT%H:%M")
            for sched in read_schedules():
                if not sched.get("enabled"):
                    continue
                sid  = sched["id"]
                cron = sched.get("cron", {})
                with _fired_lock:
                    already = _fired.get(str(sid)) == now_min
                if already:
                    continue
                if cron_matches(cron, now):
                    with _fired_lock:
                        _fired[str(sid)] = now_min
                    _execute_schedule(sid, "scheduler")
        except Exception as e:
            log.error("[SCHED] Loop error: %s", e)
        time.sleep(30)


# ─────────────────────────────────────────────────────────────────────────────
# HTTP API — stdlib HTTPServer, zero deps
# ─────────────────────────────────────────────────────────────────────────────

CORS = {
    "Access-Control-Allow-Origin":  "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
}

class Handler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *a):
        log.debug("HTTP " + fmt, *a)

    def _send(self, code: int, body: Any):
        payload = json.dumps(body, default=str).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        for k, v in CORS.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(payload)

    def _ok(self, data: Dict = None):
        self._send(200, {"ok": True, **(data or {})})

    def _err(self, msg: str, code: int = 400):
        self._send(code, {"ok": False, "error": msg})

    def _body(self) -> Dict:
        n = int(self.headers.get("Content-Length", 0))
        if n == 0:
            return {}
        try:
            return json.loads(self.rfile.read(n))
        except Exception:
            return {}

    def _path(self) -> str:
        return self.path.split("?")[0]

    def _qs(self) -> Dict[str, str]:
        qs = self.path.split("?", 1)[1] if "?" in self.path else ""
        r: Dict[str, str] = {}
        for p in qs.split("&"):
            if "=" in p:
                k, v = p.split("=", 1)
                r[k] = v
        return r

    def do_OPTIONS(self):
        self.send_response(204)
        for k, v in CORS.items():
            self.send_header(k, v)
        self.end_headers()

    def do_GET(self):
        p = self._path()

        if p == "/api/schedules":
            return self._send(200, read_schedules())

        if p == "/api/ssh/settings":
            return self._send(200, read_ssh())

        if p == "/api/scheduler/status":
            jobs = []
            for s in read_schedules():
                if not s.get("enabled"):
                    continue
                sid = s["id"]
                with _registry_lock:
                    runs = _run_registry.get(sid, [])
                last = runs[0] if runs else None
                jobs.append({
                    "jobId":      f"sched_{sid}",
                    "scheduleId": sid,
                    "name":       s.get("name", f"Schedule {sid}"),
                    "nextRun":    next_run_iso(s.get("cron", {})),
                    "lastRun": {
                        "startedAt":  last["startedAt"]  if last else None,
                        "finishedAt": last["finishedAt"] if last else None,
                        "status":     last["status"]     if last else None,
                        "exitCode":   last["exitCode"]   if last else None,
                    } if last else None,
                })
            return self._ok({
                "running": True, "schedulerState": "running",
                "jobs": jobs,
                "time": datetime.now(timezone.utc).isoformat(),
            })

        if p == "/api/scheduler/logs":
            q   = self._qs()
            raw = q.get("id", "")
            sid = int(raw) if raw.lstrip("-").isdigit() else None
            n   = int(q.get("n", 200))
            limit = int(q.get("limit", 7))   # how many runs to return logs for
            if sid is None:
                return self._err("id parameter required")
            with _registry_lock:
                runs = list(_run_registry.get(sid, []))
            if not runs:
                return self._ok({"scheduleId": sid, "runs": []})
            enriched = []
            for i, r in enumerate(runs[:limit]):
                enriched.append({
                    "runIndex":    i,
                    "startedAt":   r["startedAt"],
                    "finishedAt":  r["finishedAt"],
                    "status":      r["status"],
                    "exitCode":    r["exitCode"],
                    "triggeredBy": r.get("triggeredBy", "scheduler"),
                    "logFile":     r.get("logFile"),
                    "log":         r["log"][-n:],
                })
            return self._ok({"scheduleId": sid, "runs": enriched})

        self._err("Not found", 404)

    def do_POST(self):
        p    = self._path()
        body = self._body()

        if p == "/api/schedules/save":
            schedules = body.get("schedules")
            if not isinstance(schedules, list):
                return self._err("schedules must be an array")
            write_schedules(schedules)
            log.info("[API] Saved %d schedule(s)", len(schedules))
            return self._ok({"count": len(schedules)})

        if p == "/api/schedules/delete":
            sid = body.get("id")
            if sid is None:
                return self._err("id is required")
            schedules = [s for s in read_schedules() if s.get("id") != sid]
            write_schedules(schedules)
            return self._ok()

        if p == "/api/ssh/save":
            allowed = ["mode", "sshHost", "sshPort", "sshUser", "sshKey", "scriptDir"]
            settings = {k: body[k] for k in allowed if k in body}
            write_ssh(settings)
            log.info("[API] SSH saved: %s@%s", settings.get("sshUser","?"), settings.get("sshHost","?"))
            return self._ok({"settings": settings})

        if p == "/api/scheduler/run-now":
            sid = body.get("id")
            if sid is None:
                return self._err("id is required")
            schedules = read_schedules()
            sched = next((s for s in schedules if s.get("id") == int(sid)), None)
            if not sched:
                return self._err(f"Schedule id={sid} not found")
            # Accept triggeredBy from request (e.g. "manual:alice") so we know which user fired it.
            triggered_by = str(body.get("triggeredBy") or "manual")
            # Accept confFile and scriptDir overrides from the GUI — these reflect
            # the profile currently selected in the dropdown at click time, which may
            # differ from the stale values saved in the schedules file.
            override_conf       = (body.get("confFile")  or "").strip() or None
            override_script_dir = (body.get("scriptDir") or "").strip() or None
            if override_conf or override_script_dir:
                # Shallow-copy the schedule and apply overrides so _execute_schedule
                # sees the correct paths without mutating the persisted record.
                sched = dict(sched)
                if override_conf:       sched["confFile"]  = override_conf
                if override_script_dir: sched["scriptDir"] = override_script_dir
                log.info("[API] Run-now overrides — confFile=%s scriptDir=%s",
                         override_conf, override_script_dir)
            threading.Thread(
                target=_execute_schedule, args=(int(sid), triggered_by, sched),
                daemon=True
            ).start()
            log.info("[API] Manual trigger: '%s' (id=%s, by=%s)", sched.get("name"), sid, triggered_by)
            return self._ok({"startedAt": datetime.now(timezone.utc).isoformat()})

        self._err("Not found", 404)


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

def main():
    log.info("=" * 60)
    log.info("  SparseClone Scheduler Daemon  (zero dependencies)")
    log.info("  Python  : %s", sys.version.split()[0])
    log.info("  Data    : %s", DATA_DIR)
    log.info("  Port    : %s", args.port)
    log.info("=" * 60)

    schedules = read_schedules()
    enabled   = [s for s in schedules if s.get("enabled")]
    log.info("[BOOT] %d schedule(s) loaded, %d enabled", len(schedules), len(enabled))

    ssh = read_ssh()
    if ssh.get("sshHost"):
        log.info("[BOOT] SSH: %s@%s:%s  key: %s",
                 ssh.get("sshUser","oracle"), ssh.get("sshHost"),
                 ssh.get("sshPort", 22), ssh.get("sshKey","(default)"))
    else:
        log.warning("[BOOT] No SSH settings yet — configure via GUI Scheduler tab")

    threading.Thread(target=_scheduler_loop, daemon=True, name="cron-loop").start()

    server = HTTPServer((args.host, args.port), Handler)
    log.info("[BOOT] API listening on http://%s:%s", args.host, args.port)
    log.info("[BOOT] Ready — cron loop running, waiting for scheduled jobs")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("\n[SHUTDOWN] Stopping...")
    finally:
        server.server_close()
        log.info("[SHUTDOWN] Done.")

if __name__ == "__main__":
    main()
