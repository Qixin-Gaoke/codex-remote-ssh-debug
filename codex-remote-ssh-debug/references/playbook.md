# Codex Desktop Remote SSH Debug Playbook

## Principles

- Inspect first. Prefer read-only probes before changing files or killing processes.
- Keep auth, transport, and runtime separate:
  - auth is `~/.codex/auth.json` and `codex login status`;
  - transport is the remote reaching Codex through direct network or a local-machine VPN/proxy tunnel;
  - runtime is Desktop's SSH bootstrap, app-server socket/proxy, websocket, and rollout/session files.
- A working VPN tunnel does not imply correct auth. Correct auth does not imply the remote can reach the Codex backend.
- Treat `~/.codex/auth.json` as sensitive. Print shape only, never values.
- Codex Desktop uses a login shell bootstrap. User startup files can break a non-PTY SSH command even when normal `ssh host` works.

## Safe Probe

Run:

```sh
scripts/codex_remote_probe.sh <ssh-alias>
```

It checks:

- `codex` discovery and version;
- auth shape without token values;
- `codex login status` without token values;
- app-server process trees;
- app-server socket and log;
- proxy ports `27890` and `27897`;
- Codex backend reachability through `CODEX_SSH_PROXY_URL` or `127.0.0.1:27897` when present;
- first matching app-server environment proxy variables;
- likely PATH shadowing points.
- optional thread presence in `state_*.sqlite`, `sessions/**`, and `shell_snapshots/**` when a thread id is passed.

For a missing thread after reconnect:

```sh
scripts/codex_remote_probe.sh <ssh-alias> <thread-id>
```

## Auth Shape

Correct ChatGPT login shape:

```text
auth_mode=chatgpt
OPENAI_API_KEY is null=True
tokens exists=True
```

Wrong shape for login-token use:

```text
auth_mode=...
OPENAI_API_KEY is null=False
tokens exists=False
```

If the user expects ChatGPT login, do not use access tokens as `OPENAI_API_KEY`. Back up the remote file before replacing or removing it:

```sh
ssh <host> 'cd ~/.codex && cp -p auth.json auth.json.bak-wrong-api-key-$(date +%Y%m%d-%H%M%S)'
```

When copying a known-good login file, verify only shape:

```sh
ssh <host> 'mkdir -p ~/.codex && [ ! -f ~/.codex/auth.json ] || cp -p ~/.codex/auth.json ~/.codex/auth.json.bak-$(date +%Y%m%d-%H%M%S)'
scp ~/.codex/auth.json <host>:~/.codex/auth.json.upload
ssh <host> 'install -m 600 ~/.codex/auth.json.upload ~/.codex/auth.json && rm ~/.codex/auth.json.upload'
```

Then verify with:

```sh
ssh <host> 'codex login status'
```

Thread-proven rule: `codex login --with-api-key` can succeed and still be the wrong login mode. It writes API-key auth, not ChatGPT login-token auth. If a remote smoke test says:

```text
ERROR: Quota exceeded. Check your plan and billing details.
```

while the user expects to use their ChatGPT/Codex account quota, copy or perform a ChatGPT login instead of retrying more API keys. A minimal smoke test, only when the user accepts spending a small model call:

```sh
ssh <host> 'export HTTP_PROXY=http://127.0.0.1:27897 HTTPS_PROXY=http://127.0.0.1:27897 ALL_PROXY=http://127.0.0.1:27897; codex login status; timeout 120 codex exec --ephemeral --skip-git-repo-check -s read-only -m gpt-5.4-mini "Reply exactly: codex-smoke-ok"'
```

Passing evidence:

```text
Logged in using ChatGPT
codex-smoke-ok
```

## Desktop Bootstrap Shape

Codex Desktop typically runs a command like:

```sh
CODEX_REMOTE_PAYLOAD="$payload"; export CODEX_REMOTE_PAYLOAD
exec "$SHELL" -l -i -c 'exec /bin/sh -c "$CODEX_REMOTE_PAYLOAD"'
```

Implications:

- `.profile` and `.bashrc` can run even for non-PTY commands.
- Heavy `source` calls, warnings, password checks, and environment managers can delay or pollute bootstrap.
- If bootstrap times out, inspect startup files and test with a Desktop-shaped command, not only `ssh host command`.

Fast path for bash startup files, after backing up `.bashrc`:

```sh
# Codex Desktop remote SSH bootstrap: skip interactive-only initialization.
if [ -n "${CODEX_REMOTE_PAYLOAD:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
```

Place it before heavy interactive initialization.

## PATH Shadowing

Desktop prepends:

```sh
PATH="${CODEX_INSTALL_DIR:-$HOME/.local/bin}:$PATH"
```

Check all candidates:

```sh
ssh <host> 'PATH="${CODEX_INSTALL_DIR:-$HOME/.local/bin}:$PATH"; command -v codex; type -a codex 2>/dev/null || true'
ssh <host> 'for p in ~/.local/bin/codex /usr/local/bin/codex /usr/bin/codex /opt/node-v22-lts/bin/codex; do [ -e "$p" ] && { ls -l "$p"; head -5 "$p" 2>/dev/null || true; }; done'
```

If wrapping Codex to force proxy variables, ensure `~/.local/bin/codex` is also the wrapper, not only `/usr/local/bin/codex`.

## App-Server Socket Conflicts

Symptoms:

```text
Codex app-server websocket closed (code=1006)
Error: app-server control socket is already in use
```

Observed failure pattern from a repaired Desktop SSH session:

- the UI could spin or fail to load a known remote thread;
- `read_thread` could temporarily return "No Codex thread found" even though the rollout JSONL and `state_*.sqlite` row existed;
- the probe showed more than one `codex app-server --listen unix://` or `codex app-server proxy` process tree for the same remote user;
- `${CODEX_HOME:-$HOME/.codex}/app-server-control/app-server.log` contained `Error: app-server control socket is already in use`;
- ChatGPT auth shape was healthy (`auth_mode=chatgpt`, `OPENAI_API_KEY` null, `tokens` present), so this was not an API-key or login-token issue;
- the reverse proxy listener was still present, so the fix was the app-server/socket layer, not the VPN tunnel.

Check:

```sh
ssh <host> 'ps -eo pid,ppid,lstart,comm,args | grep -E "[c]odex app-server|[n]ode .*codex"'
ssh <host> 'ls -la ${CODEX_HOME:-$HOME/.codex}/app-server-control; sed -n "1,120p" ${CODEX_HOME:-$HOME/.codex}/app-server-control/app-server.log'
```

Targeted cleanup:

```sh
ssh <host> 'ps -eo pid,comm,args | awk '\''($2=="node" || $2=="codex") && $0 ~ /app-server/ {print $1}'\'' | xargs -r kill -9; rm -rf ${CODEX_HOME:-$HOME/.codex}/app-server-control'
```

Avoid `pkill -f "codex app-server"` from inside a shell command that contains that same string; it can kill the current SSH command.

After cleanup, rerun the probe. A healthy recovery has one app-server tree at most, a freshly-created `app-server-control.sock`, and an empty or non-fatal `app-server.log`. Preserve reverse SSH tunnel processes such as `ssh -N -T ... -R 127.0.0.1:27897:127.0.0.1:7897`; they are transport and should not be killed as part of app-server cleanup.

After changing auth shape or proxy environment, restart the target user's app-server/proxy so Desktop uses the new state. Prefer targeted process selection; avoid matching the current SSH command line:

```sh
ssh <host> 'ps -eo pid,comm,args | awk '\''($2=="node" || $2=="codex") && $0 ~ /app-server/ {print $1}'\'' | xargs -r kill; sleep 1; ps -eo pid,ppid,etime,command | grep -E "[c]odex app-server" || true'
```

Desktop may restart the daemon automatically on the next interaction. Verify the new process environment includes expected proxy variables before resending work.

## Missing Thread After Reconnect

If a thread id is not listed after an app-server repair, do not assume the session was deleted. Check remote storage:

```sh
ssh <host> 'find ~/.codex/sessions -type f -name "*<thread-id>*.jsonl" -print'
ssh <host> 'find ~/.codex/shell_snapshots -type f -name "*<thread-id>*" -print 2>/dev/null || true'
ssh <host> 'python3 - <<'"'"'PY'"'"'
import pathlib, sqlite3
needle="<thread-id>"
for db in pathlib.Path.home().joinpath(".codex").glob("state_*.sqlite"):
    con=sqlite3.connect(str(db))
    try:
        row=con.execute("select id, rollout_path, archived, cwd, updated_at from threads where id=?", (needle,)).fetchone()
        if row:
            print(db, row)
    finally:
        con.close()
PY'
```

If the rollout JSONL and `threads` row exist and `archived=0`, the data is present. Let Desktop reload after the app-server/socket fix, or navigate to the thread again. Treat this as a remote app-server/index exposure problem, not as session loss.

If Desktop says the thread is archived but unarchive fails with a missing archived rollout path:

```text
session <id> is archived
failed to resolve rollout path ~/.codex/archived_sessions/rollout-...-<id>.jsonl: file does not exist
rollout path ... must be in archived directory
```

Search for the rollout by id:

```sh
ssh <host> 'find ~/.codex -maxdepth 5 -type f -name "*<thread-id>*" -print'
```

If the file exists under `~/.codex/sessions/...` but Desktop expects it under `~/.codex/archived_sessions/...`, copy the physical file into `archived_sessions` before unarchiving. A symlink may be rejected because Desktop checks that the rollout path is in the archived directory:

```sh
ssh <host> 'src="$HOME/.codex/sessions/YYYY/MM/DD/rollout-...-<thread-id>.jsonl"; dst="$HOME/.codex/archived_sessions/$(basename "$src")"; mkdir -p "$(dirname "$dst")"; cp -p "$src" "$dst"'
```

This is a Desktop runtime/session-state issue, not a network or auth issue.

## Reverse VPN Tunnel

When remote Codex must use the user's local VPN or Clash proxy:

```sh
ssh -N -T \
  -o BatchMode=yes \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -R 127.0.0.1:27897:127.0.0.1:7897 \
  <host>
```

Validate from remote:

```sh
ssh <host> 'ss -ltnp | grep 27897; curl -I --max-time 20 -x http://127.0.0.1:27897 https://api.openai.com'
```

A Cloudflare `421` after `HTTP/1.1 200 Connection established` still proves the proxy tunnel is working.

For Codex Desktop specifically, probe the Codex backend:

```sh
ssh <host> 'curl --proxy http://127.0.0.1:27897 -I -m 20 https://chatgpt.com/backend-api/codex/responses | sed -n "1,8p"'
```

Transport is healthy if the response includes:

```text
HTTP/1.1 200 Connection established
HTTP/2 405
```

`405` is acceptable for a `HEAD`/wrong-method probe; it means the tunnel reached the Codex backend. If direct `curl --noproxy "*"` times out but the proxy probe reaches `405`, fix the tunnel/proxy environment, not auth.

Keep the model of the system separate:

- ChatGPT login state lives in `~/.codex/auth.json`; inspect only shape, never token values.
- Reverse SSH tunnels and proxy ports (`27897`, local Clash-style ports such as `7897`) are network transport.
- `app-server-control.sock`, `codex app-server --listen unix://`, and `codex app-server proxy` are the Desktop remote runtime link.

Fix the layer that evidence points to. A healthy ChatGPT auth shape plus a live reverse tunnel does not rule out stale app-server sockets.

In one verified setup, local LaunchAgents kept remote `127.0.0.1:27897` forwarded to a local proxy on `127.0.0.1:7897`. Remote shell startup exported `CODEX_SSH_PROXY_URL=http://127.0.0.1:27897`, while full `HTTP_PROXY`/`HTTPS_PROXY` was applied only for the Desktop app-server payload. This avoided turning every ordinary SSH command into a proxied command.

## Codex-Only Reverse Proxy Without Global Remote Proxy

Thread `019f39af-f94e-7072-81a0-26a3f3c13e83` repaired a remote named `180-ascend-bench` whose normal SSH worked, but Codex Desktop remote threads repeatedly timed out after the proxy setup was changed to avoid sending all remote traffic through the user's local VPN.

Observed shape:

- direct SSH to `180-ascend-bench` worked;
- a Codex-specific alias used `RemoteForward 27897 127.0.0.1:7897` with `ExitOnForwardFailure yes`;
- local proxy `127.0.0.1:7897` was reachable;
- remote `127.0.0.1:27897` was already listening, so a second tunnel attempt failed with `remote port forwarding failed for listen port 27897`;
- remote shells had `CODEX_SSH_PROXY_URL=http://127.0.0.1:27897` but intentionally did not have global `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`;
- app-server logs repeated `failed to refresh available models: timeout waiting for child process to exit` and MCP `http/request failed` lines for `https://chatgpt.com/backend-api/ps/mcp`.

Transport versus auth check:

```sh
nc -vz 127.0.0.1 7897
ssh 180-ascend-bench 'ss -ltnp | grep 27897'
ssh 180-ascend-bench 'timeout 8 curl -sS -o /tmp/codex_proxy_test.out -w "proxy_http=%{http_code} total=%{time_total}\n" --proxy http://127.0.0.1:27897 https://api.openai.com/v1/models; head -c 120 /tmp/codex_proxy_test.out; echo'
```

If the proxied request returns `401` with a "Missing bearer authentication" style body, the tunnel is working. That is a transport success because no bearer header was supplied. It is not evidence of a bad ChatGPT login token or wrong API key.

Also test the direct remote path:

```sh
ssh 180-ascend-bench 'timeout 8 curl -sS -o /tmp/codex_direct_test.out -w "direct_http=%{http_code} total=%{time_total}\n" https://api.openai.com/v1/models || true'
```

If direct remote curl times out while proxied curl reaches `401`, the problem is network routing for the remote app-server, not authentication.

In this thread, the remote Codex binary exposed standard proxy environment names such as `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, and lowercase variants, but did not show `CODEX_SSH_PROXY_URL` in `strings`. The reusable rule is: do not rely on `CODEX_SSH_PROXY_URL` alone for older remote Codex versions or child processes. Ensure the app-server process has standard proxy variables.

To avoid routing ordinary experiments through the local VPN, inject standard proxy variables only for Codex app-server payloads. Put the block before the interactive return in remote `.bashrc`, after making a backup:

```sh
cp -p ~/.bashrc ~/.bashrc.bak-codex-proxy-$(date +%Y%m%d)
```

```sh
# Codex app-server-only proxy env via SSH remote forward.
# This keeps normal SSH sessions and experiment commands off the local VPN.
case "${CODEX_REMOTE_PAYLOAD:-}" in
  *"codex app-server"*)
    export HTTP_PROXY="${CODEX_SSH_PROXY_URL:-http://127.0.0.1:27897}"
    export HTTPS_PROXY="${CODEX_SSH_PROXY_URL:-http://127.0.0.1:27897}"
    export ALL_PROXY="${CODEX_SSH_PROXY_URL:-http://127.0.0.1:27897}"
    export http_proxy="$HTTP_PROXY"
    export https_proxy="$HTTPS_PROXY"
    export all_proxy="$ALL_PROXY"
    export NO_PROXY="localhost,127.0.0.1,::1"
    export no_proxy="$NO_PROXY"
    ;;
esac
```

Validate both paths:

```sh
ssh 180-ascend-bench 'CODEX_REMOTE_PAYLOAD="codex app-server proxy" bash -lic '\''printf "HTTP_PROXY=%s\nHTTPS_PROXY=%s\nALL_PROXY=%s\nNO_PROXY=%s\n" "$HTTP_PROXY" "$HTTPS_PROXY" "$ALL_PROXY" "$NO_PROXY"'\'''
ssh 180-ascend-bench 'bash -lc '\''printf "normal_HTTP_PROXY=%s\n" "${HTTP_PROXY:-none}"'\'''
```

The app-server-shaped shell should show `http://127.0.0.1:27897`. The normal shell should remain `none`. After restarting the target app-server/proxy, verify its process environment contains standard proxy variables without printing any auth fields.

## Wrapper Pattern

Use only when the remote must always use the reverse tunnel. Preserve login auth shape.

```sh
#!/bin/sh
proxy_url="${CODEX_SSH_PROXY_URL_OVERRIDE:-http://127.0.0.1:27897}"
export CODEX_SSH_PROXY_URL="$proxy_url"
export HTTP_PROXY="$proxy_url"
export HTTPS_PROXY="$proxy_url"
export http_proxy="$proxy_url"
export https_proxy="$proxy_url"
export NO_PROXY="localhost,127.0.0.1,::1"
export no_proxy="localhost,127.0.0.1,::1"
exec /usr/local/bin/codex-real "$@"
```

Install it consistently in every path Desktop may use, especially `$HOME/.local/bin/codex`.

## Local Stuck Bootstrap Processes

If the UI keeps spinning after remote fixes, inspect local stale SSH commands:

```sh
ps aux | grep -E 'ssh .*<host>' | grep -v grep
lsof -nP -iTCP@<host-ip>:22
```

Kill stuck Desktop bootstrap SSH processes, but preserve reverse tunnel processes such as:

```text
ssh -N -T ... -R 127.0.0.1:27897:127.0.0.1:7897 <host>
```

## Host Key And MaxStartups

If SSH fails before authentication:

- `REMOTE HOST IDENTIFICATION HAS CHANGED`: back up `known_hosts`, remove only the offending host:port, rescan keys.
- `Exceeded MaxStartups` or `banner exchange timeout`: reduce concurrent probes, wait, and avoid parallel SSH calls.

In thread `019f39af-f94e-7072-81a0-26a3f3c13e83`, `Exceeded MaxStartups` was caused by a local launchd tunnel checker repeatedly opening SSH sessions every minute. The checker intended to keep `180-ascend-bench-codex` alive, but its remote health test ran direct `curl -I https://api.openai.com` without `--proxy`. Because normal remote shells intentionally had no global proxy, the health check always failed, restarted the tunnel, and created an SSH connection storm.

Check for this pattern locally:

```sh
launchctl print gui/$(id -u)/com.shuhao.codex-ssh-forward-180-ascend-bench 2>/dev/null | sed -n '1,120p'
sed -n '1,220p' ~/.local/bin/codex-ssh-forward-180-ascend-bench
tail -80 ~/.codex/log/codex-ssh-forward-180-ascend-bench.log
ps aux | grep -E 'ssh .*180-ascend-bench' | grep -v grep
```

The reusable fix is to make the checker test the remote proxy explicitly, and to match tunnel processes broadly enough when restarting:

```sh
REMOTE_PROXY="http://127.0.0.1:27897"
remote_proxy_ready() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$DIRECT_HOST" \
    "curl -I --proxy '$REMOTE_PROXY' --max-time 12 '$REMOTE_CHECK_URL' >/dev/null 2>&1"
}

restart_forward() {
  pkill -f "ssh .*${FORWARD_HOST}" >/dev/null 2>&1 || true
  ssh -fN "$FORWARD_HOST"
}
```

When stabilizing the storm, stop the launchd job first, clean up stale local SSH attempts, then restart after the checker is fixed:

```sh
launchctl bootout gui/$(id -u) com.shuhao.codex-ssh-forward-180-ascend-bench
pkill -f 'ssh .*180-ascend-bench-codex' || true
~/.local/bin/codex-ssh-forward-180-ascend-bench
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.shuhao.codex-ssh-forward-180-ascend-bench.plist
launchctl kickstart -k gui/$(id -u)/com.shuhao.codex-ssh-forward-180-ascend-bench
```

If a remote app-server log contains `Error: app-server control socket is already in use`, first check whether a healthy app-server and proxy are already running. In this thread the line appeared during duplicate bootstrap attempts; it was not fatal once a single current app-server/proxy tree and socket existed.

## Final Validation Checklist

- `ssh <host> 'printf MAGIC'` returns clean stdout and no unexpected stderr.
- Desktop-shaped install check returns magic bytes quickly.
- Desktop-shaped app-server bootstrap returns magic bytes and creates a socket.
- `type -a codex` resolves to the intended wrapper/binary.
- No duplicate app-server trees exist.
- Reverse tunnel process is running when needed.
- The Codex backend proxy probe reaches `HTTP/2 405` when a local VPN tunnel is required.
- Auth shape is correct for the user's intended mode, and `codex login status` agrees.
- If quota was suspected, a tiny `codex exec --ephemeral` smoke test distinguishes API-key quota failure from ChatGPT login success.
