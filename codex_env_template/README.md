# Reusable Codex Command Bridge Template

This directory is a reusable template for giving a Codex/LLM development agent limited operational access to a host project.

The technique is a capability-gated host command bridge:

```txt
Codex container -> bin/devctl -> forced SSH command -> sudo allowlist -> /usr/local/bin/codex-devctl -> approved host commands
```

The LLM stays inside a Docker container. It can only ask the host to run commands explicitly listed in the bridge allowlists.

## What You Get

```txt
codex_env_template/
  Dockerfile.codex                  Minimal Codex/LLM container image
  README.md                         This reusable setup guide
  bash_script/
    helper_script.sh                Host setup and bridge generation helpers
    codex_whitelist.sh              Host command allowlist installer
  bin/
    devctl                          Codex-side SSH wrapper
```

## Security Model

This template narrows access, but it is not magic security isolation.

Controls provided:

- No unrestricted host shell for the LLM.
- SSH key is forced to run only `/usr/local/bin/codex-ssh-gateway`.
- The forced gateway forwards only approved command names.
- `sudo` is limited to approved `/usr/local/bin/codex-devctl ...` calls.
- Host commands are implemented in one small script: `bash_script/codex_whitelist.sh`.
- Container aliases and URL targets are resolved by the whitelist script.

The main rule: add narrow commands for specific workflows instead of exposing generic shell access.

## Copy Into Another Project

From a project root:

```bash
cp -a /path/to/codex_env_template ./codex_env
cd codex_env
```

You can keep the directory name `codex_env` or choose another name. The helper script infers the project root as the parent directory of this template copy.

## Host Requirements

- Docker
- OpenSSH server
- `sudo`
- `bash`
- `visudo`
- Network access from the Codex container to `host.docker.internal`

## Default Names

The helper uses these defaults unless overridden by environment variables:

```txt
CODEX_IMAGE=codex_agent_img
CODEX_CONTAINER=codex_agent_cont
CODEX_NETWORK=bridge
CODEX_WORKDIR=/workspace
CODEX_RUNNER_USER=codex-runner
CODEX_RUNNER_HOST=host.docker.internal
CODEX_DEVCTL=/usr/local/bin/codex-devctl
```

The host command allowlist uses these defaults:

```txt
CODEX_PROJECT_DIR=<parent of this template directory>
CODEX_FRONTEND_DIR=$CODEX_PROJECT_DIR/front_end
CODEX_API_DIR=$CODEX_PROJECT_DIR/rest_api
CODEX_COMPOSE_FILE=$CODEX_PROJECT_DIR/docker-compose.yml
CODEX_FRONT_CONTAINER=front
CODEX_API_CONTAINER=api
CODEX_DB_CONTAINER=db
CODEX_FRONT_PORT=3000
CODEX_API_PORT=3000
CODEX_FRONT_HOST_PORT=$CODEX_FRONT_PORT
CODEX_API_HOST_PORT=$CODEX_API_PORT
```

Override them before installing the bridge when your project uses different names:

```bash
export CODEX_NETWORK=my_docker_network
export CODEX_FRONT_CONTAINER=my_front_container
export CODEX_API_CONTAINER=my_api_container
export CODEX_DB_CONTAINER=my_db_container
export CODEX_API_PORT=3004
export CODEX_API_HOST_PORT=3004
export CODEX_FRONT_PORT=3000
export CODEX_FRONT_HOST_PORT=8080
```

## Initial Container Setup

From the copied template directory:

```bash
source bash_script/helper_script.sh
codex_env_build_img
codex_env_login
```

`codex_env_login` starts the Codex container and mounts the project root at `/workspace`.

Useful lifecycle helpers:

```bash
codex_env_start      # Start and attach to existing container
codex_env_shell      # Open shell in running container
codex_env_stop       # Stop container
codex_env_rm         # Remove stopped container
codex_env_reset      # Force-remove container
```

## Install The Command Bridge

Run from the host after sourcing `helper_script.sh`:

```bash
codex_env_build_capability_gated_command_bridge
```

This installs or refreshes:

- `/usr/local/bin/codex-devctl`
- sudoers rules for your host user and `codex-runner`
- the `codex-runner` host user if missing
- the SSH keypair in `$HOME/.local/share/codex-command-bridge/secrets/`
- `/usr/local/bin/codex-ssh-gateway`
- the Codex-side wrapper at `bin/devctl`
- the runner SSH key and known host inside the Codex container

If the Codex container is not running, key mounting will fail. Start the container first with `codex_env_login` or `codex_env_start`.

## Use From Inside The Codex Container

```bash
codex_env/bin/devctl <command> [args...]
```

Examples:

```bash
codex_env/bin/devctl project-status
codex_env/bin/devctl project-diff
codex_env/bin/devctl ps
codex_env/bin/devctl logs api
codex_env/bin/devctl smoke-url api:3000
codex_env/bin/devctl front-typecheck
codex_env/bin/devctl front-build
codex_env/bin/devctl api-build
codex_env/bin/devctl api-test
```

## Default Allowed Commands

The template starts with these commands:

```txt
project-status     Show `git status --short` for the project
project-diff       Show `git diff --stat` for the project
project-files      List project files up to CODEX_FIND_DEPTH
ps                 Show configured front/api/db containers
logs <alias>       Show logs for front, api, or db
ip <alias>         Show Docker IP for front, api, or db
smoke-url <target> Run `curl -I` against a URL, host:port, or alias
compose-ps         Run `docker compose ps`
compose-up         Run `docker compose up -d`
compose-down       Run `docker compose down`
front-lint         Run `npm run lint` in CODEX_FRONTEND_DIR
front-typecheck    Run `npx tsc --noEmit` in CODEX_FRONTEND_DIR
front-build        Run `npm run build` in CODEX_FRONTEND_DIR
front-test         Run `npm test` in CODEX_FRONTEND_DIR
api-build          Run CMake configure/build in CODEX_API_DIR
api-test           Run CTest in CODEX_API_DIR/build
```

Container aliases accepted by default:

```txt
front, frontend
api, rest, backend
db, database, mysql, postgres
```

## Customize Commands For A Project

There are two places to update when adding or removing commands:

1. `bash_script/helper_script.sh`

   Update `CODEX_ALLOWED_COMMANDS`. This list generates:

   - the Codex-side `bin/devctl` wrapper
   - the forced SSH gateway
   - the sudoers allowlist

2. `bash_script/codex_whitelist.sh`

   Add the command implementation inside the `case "$cmd" in ... esac` block.

After changes, rebuild the bridge:

```bash
source bash_script/helper_script.sh
codex_env_build_capability_gated_command_bridge
```

Then test from inside the Codex container:

```bash
codex_env/bin/devctl project-status
```

## Recommended Command Design

Prefer commands like these:

```txt
front-typecheck
front-build
api-unit-tests
api-smoke-search
migration-status
container-logs-api
```

Avoid commands like these unless you fully understand the risk:

```txt
shell
exec
bash
sh
run-anything
```

If you need a shell-like workflow, encode the specific action as a named command instead.

## Troubleshooting

### `Denied local command`

The command is not allowed by `bin/devctl`. Update `CODEX_ALLOWED_COMMANDS` and regenerate:

```bash
codex_env_create_codex_side_devctl
```

### `Denied SSH command`

The forced SSH gateway does not allow the command. Rebuild the bridge:

```bash
codex_env_build_capability_gated_command_bridge
```

### `sudo: a password is required`

The sudoers rule is missing or stale:

```bash
codex_env_install_devctl_sudoers
codex_env_install_runner_devctl_sudoers
```

### SSH key or known-host failures

Refresh the SSH bridge and remount the key:

```bash
codex_env_build_ssh_bridge
codex_env_force_ssh_gateway
codex_env_mount_ssh_key
```

### Wrong project path

Set `CODEX_PROJECT_DIR` before installing the host devctl:

```bash
export CODEX_PROJECT_DIR=/absolute/path/to/my/project
codex_env_install_host_devctl
```

Then rebuild the bridge if sudoers/gateway also changed.

## Files To Keep In Sync

- `bash_script/helper_script.sh`: bridge setup and allowed command names
- `bash_script/codex_whitelist.sh`: host command implementations
- `bin/devctl`: generated Codex-side wrapper
- `/usr/local/bin/codex-ssh-gateway`: generated forced SSH gateway
- `/etc/sudoers.d/codex-devctl-*`: generated sudo allowlists

## Short Description

A reusable, capability-gated host command bridge for LLM coding agents. The LLM runs in a Docker container and can execute only whitelisted host operations through a forced SSH command, a dedicated runner user, and sudoers-limited command controller.
