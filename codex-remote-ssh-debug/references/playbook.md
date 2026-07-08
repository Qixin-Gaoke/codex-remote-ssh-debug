# Codex Desktop Remote SSH Debug Playbook

## Principles

- Inspect first. Prefer read-only probes before changing files or killing processes.
- Keep auth and transport separate. A working VPN tunnel does not imply an API-key auth mode.
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
- app-server process trees;
- app-server socket and log;
- proxy ports `27890` and `27897`;
- first matching app-server environment proxy variables;
- likely PATH shadowing points.

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
scp ~/.codex/auth.json <host>:/root/.codex/auth.json.upload
ssh <host> 'install -m 600 auth.json.upload ~/.codex/auth.json && rm auth.json.upload'
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

## Final Validation Checklist

- `ssh <host> 'printf MAGIC'` returns clean stdout and no unexpected stderr.
- Desktop-shaped install check returns magic bytes quickly.
- Desktop-shaped app-server bootstrap returns magic bytes and creates a socket.
- `type -a codex` resolves to the intended wrapper/binary.
- No duplicate app-server trees exist.
- Reverse tunnel process is running when needed.
- Auth shape is correct for the user's intended mode.
