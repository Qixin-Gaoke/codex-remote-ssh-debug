---
name: codex-remote-ssh-debug
description: Diagnose and repair Codex Desktop remote SSH connections, including SSH bootstrap timeouts, app-server websocket code 1006, stale app-server sockets, duplicate app-server/proxy trees, PATH shadowing, ChatGPT login-token versus API-key auth confusion, quota errors from wrong auth mode, missing or archived thread rollout files after reconnect, and remote networking through a local VPN/proxy tunnel. Use when Codex Desktop SSH remotes are stuck spinning, show "remote computer does not have Codex installed", "app-server bootstrap timed out", "Codex app-server websocket closed", "app-server control socket is already in use", "Quota exceeded", "stream disconnected before completion", or need a local-machine VPN/proxy for remote Codex app-server traffic.
---

# Codex Remote SSH Debug

Use this skill to debug Codex Desktop's SSH remote flow end to end: SSH bootstrap, remote `codex` discovery, app-server daemon/proxy, auth shape, and proxy/VPN routing.

## Non-Negotiables

- Do not treat ChatGPT login tokens as API keys. A correct ChatGPT login auth file has `auth_mode=chatgpt`, `OPENAI_API_KEY` set to null, and a `tokens` object.
- Keep auth, network transport, and Desktop runtime separate: `auth.json`; VPN/proxy tunnel; app-server/socket/websocket/session files.
- Do not print token values. Inspect only key names, booleans, timestamps, and file existence.
- Do not delete `~/.codex/auth.json` unless the user explicitly asks. If repairing a wrong API-key auth shape, back it up first.
- Do not overwrite user SSH config or shell startup files without backing them up.
- Do not kill unrelated SSH sessions. Preserve long-running reverse VPN tunnels unless they are the target.

## Workflow

1. Confirm the failing alias and error text from the UI.
2. Run the read-only probe:
   `scripts/codex_remote_probe.sh <ssh-alias>`
   If a specific thread is missing after reconnect, include it:
   `scripts/codex_remote_probe.sh <ssh-alias> <thread-id>`
3. Classify the failure:
   - Install/discovery failure: `command -v codex` missing or wrong PATH.
   - Bootstrap timeout: SSH command or login shell startup hangs before magic bytes return.
   - Websocket/app-server 1006: proxy cannot connect to the app-server socket, the socket is stale, or multiple app-servers/proxies fight over it.
   - Networking failure: remote app-server starts but cannot reach OpenAI without the user's local VPN/proxy, or only `CODEX_SSH_PROXY_URL` is set while child HTTP paths need standard proxy env.
   - Auth-shape failure: `auth.json` uses API-key shape when the user expects ChatGPT login, often surfacing as `Quota exceeded`.
   - Session-state failure: Desktop says a thread is missing or archived while rollout files and the thread row still exist.
4. Apply the smallest targeted fix, then rerun the probe and a Desktop-shaped bootstrap simulation.

## What To Read Next

- Read `references/playbook.md` for the full decision tree and exact commands.
- Use `scripts/codex_remote_probe.sh` for a safe status snapshot.
- Use `scripts/remote_vpn_tunnel.sh` as the template for launchd-managed reverse tunnels from a remote host to a local proxy such as Clash on `127.0.0.1:7897`.

## Common Fixes

- **PATH shadowing**: Codex Desktop prepends `${CODEX_INSTALL_DIR:-$HOME/.local/bin}`. Ensure `$HOME/.local/bin/codex` and `/usr/local/bin/codex` resolve to the same wrapper or binary.
- **Stale socket / duplicate app-servers**: If the probe shows multiple `codex app-server` or `codex app-server proxy` trees and `app-server control socket is already in use`, kill only the target user's `node`/`codex` app-server processes, then remove `${CODEX_HOME:-$HOME/.codex}/app-server-control`.
- **Slow login shell**: Codex uses the user's login shell with `-l -i`. If `.bashrc` sources heavy environment scripts, add a backed-up fast path that returns early when `CODEX_REMOTE_PAYLOAD` is set.
- **Local VPN required**: Keep a reverse SSH tunnel such as `-R 127.0.0.1:27897:127.0.0.1:7897`, then make remote Codex use `http://127.0.0.1:27897`.
- **Codex-only proxy env**: If ordinary remote shells should not burn local VPN traffic, keep generic proxy vars unset globally and inject `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` only for `CODEX_REMOTE_PAYLOAD` values that start Codex app-server.
- **Auth confusion**: Preserve ChatGPT login mode. Do not set `OPENAI_API_KEY` to an access token, and do not assume an `sk-proj...` API key uses the same quota as the user's ChatGPT/Codex login.
- **Stale app-server auth**: After changing remote auth shape, restart the target user's app-server/proxy so Desktop uses the new credentials.
- **Thread missing after reconnect**: First fix the app-server/socket layer, then rerun the probe with the thread id and check that `state_*.sqlite` and `sessions/**/rollout-*<thread-id>.jsonl` still contain the thread before assuming data loss.

## Validation

After a fix, validate all of these:

```sh
scripts/codex_remote_probe.sh <ssh-alias>
```

On the remote host, the desired state is usually:

- one app-server process tree at most;
- app-server socket exists only after Desktop starts it;
- app-server log is empty or non-fatal;
- `auth_mode=chatgpt`, `OPENAI_API_KEY is null`, and `tokens` exists when using login auth;
- `codex login status` agrees with the intended login mode;
- remote proxy port reaches the Codex backend if the remote needs the user's local VPN;
- Desktop-shaped bootstrap returns magic bytes in under a few seconds.
