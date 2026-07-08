#!/bin/sh
set -eu

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <ssh-host-alias> [thread-id]" >&2
  exit 2
fi

host="$1"
thread_id="${2:-}"

ssh -o BatchMode=yes -o ConnectTimeout=30 "$host" 'sh -s' -- "$thread_id" <<'REMOTE'
set -eu
thread_id="${1:-}"

section() {
  printf "\n=== %s ===\n" "$1"
}

section "time"
date || true

section "codex discovery"
PATH="${CODEX_INSTALL_DIR:-$HOME/.local/bin}:$PATH"
export PATH
command -v codex || true
type -a codex 2>/dev/null || true
codex --version 2>&1 || true

section "auth shape"
python3 - <<'PY' 2>/dev/null || true
import json, os
p=os.path.expanduser("~/.codex/auth.json")
if not os.path.exists(p):
    print("auth.json=missing")
    raise SystemExit
data=json.load(open(p))
print("auth_mode=" + str(data.get("auth_mode")))
print("OPENAI_API_KEY_is_null=" + str(data.get("OPENAI_API_KEY") is None))
print("has_tokens=" + str(isinstance(data.get("tokens"), dict)))
print("top_level_keys=" + ",".join(sorted(data.keys())))
PY

section "codex login status"
PATH="${CODEX_INSTALL_DIR:-$HOME/.local/bin}:$PATH"
export PATH
codex login status 2>&1 | sed -E 's/(sk-[A-Za-z0-9_-]{8})[A-Za-z0-9_-]+/\1***/g' || true

section "app-server processes"
ps -eo pid,ppid,lstart,comm,args | grep -E '[c]odex app-server|[n]ode .*codex|desktop-ssh-websocket' || true

section "app-server control"
control="${CODEX_HOME:-$HOME/.codex}/app-server-control"
ls -la "$control" 2>&1 || true
sed -n "1,160p" "$control/app-server.log" 2>/dev/null || true

section "proxy listeners"
ss -ltnp 2>/dev/null | grep -E '27890|27897|7897' || true

section "normal shell proxy env"
env | grep -E '^(CODEX_SSH_PROXY_URL|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|http_proxy|https_proxy|all_proxy|NO_PROXY|no_proxy)=' || true

section "proxy transport tests"
for port in 27897 27890; do
  if ss -ltn 2>/dev/null | grep -q "127.0.0.1:${port}\\|\\[::1\\]:${port}"; then
    out="/tmp/codex_remote_probe_proxy_${port}.out"
    printf "proxy=http://127.0.0.1:%s " "$port"
    timeout 12 curl -sS -o "$out" -w "http=%{http_code} total=%{time_total}\n" \
      --proxy "http://127.0.0.1:${port}" https://api.openai.com/v1/models 2>/dev/null || true
    head -c 160 "$out" 2>/dev/null || true
    printf "\n"
  else
    printf "proxy=http://127.0.0.1:%s listener=missing\n" "$port"
  fi
done

section "codex backend via proxy"
proxy_url="${CODEX_SSH_PROXY_URL:-}"
if [ -z "$proxy_url" ] && ss -ltn 2>/dev/null | grep -q '127.0.0.1:27897'; then
  proxy_url="http://127.0.0.1:27897"
fi
if [ -n "$proxy_url" ]; then
  echo "proxy_url_present=True"
  timeout 12 curl --proxy "$proxy_url" -I -m 12 https://chatgpt.com/backend-api/codex/responses 2>&1 | sed -n '1,8p' || true
else
  echo "proxy_url_present=False"
fi

section "app-server env"
for p in $(ps -eo pid,args | awk '/app-server/ && !/awk/ {print $1}'); do
  echo "--- PID:$p ---"
  tr "\0" "\n" <"/proc/$p/environ" 2>/dev/null | grep -Ei 'CODEX|PROXY|proxy|PATH=' || true
done

section "path candidates"
for p in "$HOME/.local/bin/codex" /usr/local/bin/codex /usr/local/bin/codex-real /usr/bin/codex /opt/node-v22-lts/bin/codex; do
  if [ -e "$p" ]; then
    ls -ld "$p"
    head -8 "$p" 2>/dev/null || true
  fi
done

if [ -n "$thread_id" ]; then
  section "thread presence"
  echo "thread_id=$thread_id"
  find "${CODEX_HOME:-$HOME/.codex}/sessions" -type f -name "*$thread_id*.jsonl" -print 2>/dev/null || true
  find "${CODEX_HOME:-$HOME/.codex}/shell_snapshots" -type f -name "*$thread_id*" -print 2>/dev/null || true
  THREAD_ID="$thread_id" python3 - <<'PY' 2>/dev/null || true
import os, pathlib, sqlite3
needle = os.environ["THREAD_ID"]
root = pathlib.Path(os.environ.get("CODEX_HOME", pathlib.Path.home() / ".codex"))
for db in sorted(root.glob("state_*.sqlite")):
    try:
        con = sqlite3.connect(str(db))
        con.row_factory = sqlite3.Row
        row = con.execute(
            "select id, rollout_path, archived, cwd, updated_at from threads where id=?",
            (needle,),
        ).fetchone()
        if row:
            print("state_db=" + str(db))
            for key in row.keys():
                print(f"{key}={row[key]}")
        con.close()
    except Exception as exc:
        print(f"state_db_error={db}:{type(exc).__name__}:{exc}")
PY
fi
REMOTE
