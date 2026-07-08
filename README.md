# codex-remote-ssh-debug

A Codex skill for diagnosing and repairing Codex Desktop SSH remotes: app-server bootstrap timeouts, websocket code 1006, stale sockets, PATH shadowing, ChatGPT login-token auth shape, and remote traffic through a local VPN/proxy tunnel.

## Install

```sh
mkdir -p ~/.codex/skills
cp -R codex-remote-ssh-debug ~/.codex/skills/
```

Then ask Codex to use `$codex-remote-ssh-debug` when debugging a remote SSH connection.
