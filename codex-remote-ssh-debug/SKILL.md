---
name: codex-remote-ssh-debug
description: Diagnose and repair Codex Desktop remote SSH connections, including SSH bootstrap timeouts, app-server websocket code 1006, stale app-server sockets, PATH shadowing, ChatGPT login-token versus API-key auth confusion, and remote networking through the user's local VPN or proxy tunnel. Use when Codex Desktop SSH remotes are stuck spinning, show "remote computer does not have Codex installed", "app-server bootstrap timed out", "Codex app-server websocket closed", or need a local-machine VPN/proxy for remote Codex traffic.
---

# Codex Remote SSH Debug

Use this skill to debug Codex Desktop's SSH remote flow end to end: SSH bootstrap, remote `codex` discovery, app-server daemon/proxy, auth shape, and proxy/VPN routing.

## Non-Negotiables

- Do not treat ChatGPT login tokens as API keys. A correct ChatGPT login auth file has `auth_mode=chatgpt`, `OPENAI_API_KEY` set to null, and a `tokens` object.
- Do not print token values. Inspect only key names, booleans, timestamps, and file existence.
- Do not delete `~/.codex/auth.json` unless the user explicitly asks. If repairing a wrong API-key auth shape, back it up first.
- Do not overwrite user SSH config or shell startup files without backing them up.
- Do not kill unrelated SSH sessions. Preserve long-running reverse VPN tunnels unless they are the target.

## Workflow

1. Confirm the failing alias and error text from the UI.
2. Run the read-only probe:
   `scripts/codex_remote_probe.sh <ssh-alias>`
3. Classify the failure:
   - Install/discovery failure: `command -v codex` missing or wrong PATH.
   - Bootstrap timeout: SSH command or login shell startup hangs before magic bytes return.
   - Websocket/app-server 1006: proxy cannot connect to the app-server socket, the socket is stale, or multiple app-servers fight over it.
   - Networking failure: remote app-server starts but cannot reach OpenAI without the user's local VPN/proxy.
   - Auth-shape failure: `auth.json` uses API-key shape when the user expects ChatGPT login.
4. Apply the smallest targeted fix, then rerun the probe and a Desktop-shaped bootstrap simulation.

## What To Read Next

- Read `references/playbook.md` for the full decision tree and exact commands.
- Use `scripts/codex_remote_probe.sh` for a safe status snapshot.
- Use `scripts/remote_vpn_tunnel.sh` as the template for launchd-managed reverse tunnels from a remote host to a local proxy such as Clash on `127.0.0.1:7897`.

## Common Fixes

- **PATH shadowing**: Codex Desktop prepends `${CODEX_INSTALL_DIR:-$HOME/.local/bin}`. Ensure `$HOME/.local/bin/codex` and `/usr/local/bin/codex` resolve to the same wrapper or binary.
- **Stale socket**: Kill only `node` or `codex` app-server processes for the target user, then remove `${CODEX_HOME:-$HOME/.codex}/app-server-control`.
- **Slow login shell**: Codex uses the user's login shell with `-l -i`. If `.bashrc` sources heavy environment scripts, add a backed-up fast path that returns early when `CODEX_REMOTE_PAYLOAD` is set.
- **Local VPN required**: Keep a reverse SSH tunnel such as `-R 127.0.0.1:27897:127.0.0.1:7897`, then make remote Codex use `http://127.0.0.1:27897`.
- **Auth confusion**: Preserve ChatGPT login mode. Do not set `OPENAI_API_KEY` to an access token.

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
- remote proxy port responds if the remote needs the user's local VPN;
- Desktop-shaped bootstrap returns magic bytes in under a few seconds.
