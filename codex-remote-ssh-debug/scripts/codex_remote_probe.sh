#!/bin/sh
set -eu

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <ssh-host-alias>" >&2
  exit 2
fi

host="$1"

ssh -o BatchMode=yes -o ConnectTimeout=30 "$host" 'sh -s' <<'REMOTE'
set -eu

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

section "app-server processes"
ps -eo pid,ppid,lstart,comm,args | grep -E '[c]odex app-server|[n]ode .*codex|desktop-ssh-websocket' || true

section "app-server control"
control="${CODEX_HOME:-$HOME/.codex}/app-server-control"
ls -la "$control" 2>&1 || true
sed -n "1,160p" "$control/app-server.log" 2>/dev/null || true

section "proxy listeners"
ss -ltnp 2>/dev/null | grep -E '27890|27897|7897' || true

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
REMOTE
