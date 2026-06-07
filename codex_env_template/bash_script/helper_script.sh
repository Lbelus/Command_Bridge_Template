#!/usr/bin/env bash
set -euo pipefail

# Reusable capability-gated command bridge for Codex/LLM development agents.
# Source this file from the host, then run the codex_env_* functions below.

CODEX_ENV_DIR="${CODEX_ENV_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CODEX_PROJECT_ROOT="${CODEX_PROJECT_ROOT:-$(cd "$CODEX_ENV_DIR/.." && pwd)}"

CODEX_IMAGE="${CODEX_IMAGE:-codex_agent_img}"
CODEX_CONTAINER="${CODEX_CONTAINER:-codex_agent_cont}"
CODEX_NETWORK="${CODEX_NETWORK:-bridge}"
CODEX_WORKDIR="${CODEX_WORKDIR:-/workspace}"
CODEX_HOME_DIR="${CODEX_HOME_DIR:-$HOME/.local/share/codex-command-bridge/codex-home}"

CODEX_RUNNER_USER="${CODEX_RUNNER_USER:-codex-runner}"
CODEX_RUNNER_HOST="${CODEX_RUNNER_HOST:-host.docker.internal}"
CODEX_SECRET_DIR="${CODEX_SECRET_DIR:-$HOME/.local/share/codex-command-bridge/secrets}"
CODEX_KEY="${CODEX_KEY:-$CODEX_SECRET_DIR/codex_runner_key}"
CODEX_DEVCTL="${CODEX_DEVCTL:-/usr/local/bin/codex-devctl}"
CODEX_SSH_GATEWAY="${CODEX_SSH_GATEWAY:-/usr/local/bin/codex-ssh-gateway}"

# Keep this list in sync with commands implemented by bash_script/codex_whitelist.sh.
# The helper uses this one list to generate sudoers, the forced SSH gateway, and the
# Codex-side wrapper.
CODEX_ALLOWED_COMMANDS=(
  project-status
  project-diff
  project-files
  ps
  logs
  ip
  smoke-url
  compose-ps
  compose-up
  compose-down
  front-lint
  front-typecheck
  front-build
  front-test
  api-build
  api-test
)

codex_env_allowed_pattern()
{
    local IFS='|'
    printf '%s' "${CODEX_ALLOWED_COMMANDS[*]}"
}

codex_env_allowed_words()
{
    printf '%s ' "${CODEX_ALLOWED_COMMANDS[@]}"
}

codex_env_build_img()
{
    sudo docker build \
        -f "$CODEX_ENV_DIR/Dockerfile.codex" \
        --build-arg UID="$(id -u)" \
        --build-arg GID="$(id -g)" \
        -t "$CODEX_IMAGE" \
        "$CODEX_ENV_DIR"
}

codex_env_run()
{
    mkdir -p "$CODEX_HOME_DIR"

    local network_args=()
    if [[ "$CODEX_NETWORK" != "bridge" ]]; then
        network_args=(--network "$CODEX_NETWORK")
    fi

    sudo docker run -it \
        --name "$CODEX_CONTAINER" \
        "${network_args[@]}" \
        --add-host=host.docker.internal:host-gateway \
        --user "$(id -u):$(id -g)" \
        -v "$CODEX_PROJECT_ROOT:$CODEX_WORKDIR" \
        -v "$CODEX_HOME_DIR:/home/codex/.codex" \
        -w "$CODEX_WORKDIR" \
        "$CODEX_IMAGE" \
        bash
}

codex_env_login()
{
    codex_env_run
}

codex_env_start()
{
    sudo docker start -ai "$CODEX_CONTAINER"
}

codex_env_shell()
{
    sudo docker exec -it "$CODEX_CONTAINER" bash
}

codex_env_stop()
{
    sudo docker stop "$CODEX_CONTAINER"
}

codex_env_rm()
{
    sudo docker rm "$CODEX_CONTAINER"
}

codex_env_reset()
{
    sudo docker rm -f "$CODEX_CONTAINER" 2>/dev/null || true
}

codex_env_install_host_devctl()
{
    sudo CODEX_PROJECT_DIR="$CODEX_PROJECT_ROOT" \
        bash "$CODEX_ENV_DIR/bash_script/codex_whitelist.sh"
}

codex_env_devctl_sudoers_line()
{
    local sudo_user="${1:-$USER}"
    local codex_devctl="${2:-$CODEX_DEVCTL}"

    printf '%s ALL=(root) NOPASSWD: ' "$sudo_user"

    local first=1
    local command_name
    for command_name in "${CODEX_ALLOWED_COMMANDS[@]}"; do
        if [[ "$first" -eq 0 ]]; then
            printf ', '
        fi
        first=0
        printf '%s %s, %s %s *' "$codex_devctl" "$command_name" "$codex_devctl" "$command_name"
    done

    printf '\n'
}

codex_env_install_devctl_sudoers()
{
    local sudo_user="${1:-$USER}"
    local codex_devctl="${2:-$CODEX_DEVCTL}"
    local sudoers_file="/etc/sudoers.d/codex-devctl-${sudo_user}"
    local tmp_file

    tmp_file="$(mktemp)"
    codex_env_devctl_sudoers_line "$sudo_user" "$codex_devctl" > "$tmp_file"

    sudo chown root:root "$tmp_file"
    sudo chmod 0440 "$tmp_file"
    sudo visudo -cf "$tmp_file"
    sudo install -o root -g root -m 0440 "$tmp_file" "$sudoers_file"
    sudo rm -f "$tmp_file"
    sudo visudo -c

    echo "Installed sudoers rule: $sudoers_file"
}

codex_env_install_runner_devctl_sudoers()
{
    codex_env_install_devctl_sudoers "$CODEX_RUNNER_USER" "$CODEX_DEVCTL"
}

codex_env_create_codex_side_devctl()
{
    local wrapper_path="${1:-$CODEX_ENV_DIR/bin/devctl}"
    local allowed_pattern
    local allowed_words

    allowed_pattern="$(codex_env_allowed_pattern)"
    allowed_words="$(codex_env_allowed_words)"

    mkdir -p "$(dirname "$wrapper_path")"

    cat > "$wrapper_path" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail

cmd="\${1:-}"
shift || true

runner_host="\${CODEX_RUNNER_HOST:-$CODEX_RUNNER_HOST}"
runner_user="\${CODEX_RUNNER_USER:-$CODEX_RUNNER_USER}"
runner_key="\${CODEX_RUNNER_KEY:-/home/codex/.ssh/id_ed25519}"
known_hosts="\${CODEX_KNOWN_HOSTS:-/home/codex/.ssh/known_hosts}"
ssh_args=(-o BatchMode=yes)

if [[ -r "\$runner_key" ]]; then
  ssh_args+=(-i "\$runner_key")
fi
if [[ -r "\$known_hosts" ]]; then
  ssh_args+=(-o UserKnownHostsFile="\$known_hosts")
fi

case "\$cmd" in
  $allowed_pattern)
    ssh "\${ssh_args[@]}" "\${runner_user}@\${runner_host}" "\$cmd" "\$@"
    ;;
  *)
    echo "Denied local command: \$cmd" >&2
    echo "Allowed: $allowed_words" >&2
    exit 2
    ;;
esac
SCRIPT

    chmod +x "$wrapper_path"
    echo "Created Codex-side devctl wrapper: $wrapper_path"
}

codex_env_create_runner_user()
{
    if ! id "$CODEX_RUNNER_USER" >/dev/null 2>&1; then
        sudo useradd -m -s /bin/bash "$CODEX_RUNNER_USER"
    fi
}

codex_env_build_ssh_bridge()
{
    codex_env_create_runner_user

    mkdir -p "$CODEX_SECRET_DIR"
    chmod 700 "$CODEX_SECRET_DIR"

    if [[ ! -f "$CODEX_KEY" ]]; then
        ssh-keygen -t ed25519 -f "$CODEX_KEY" -N ""
    fi

    chmod 600 "$CODEX_KEY"
    chmod 644 "$CODEX_KEY.pub"

    sudo mkdir -p "/home/$CODEX_RUNNER_USER/.ssh"
    sudo tee "/home/$CODEX_RUNNER_USER/.ssh/authorized_keys" >/dev/null < "$CODEX_KEY.pub"
    sudo chown -R "$CODEX_RUNNER_USER:$CODEX_RUNNER_USER" "/home/$CODEX_RUNNER_USER/.ssh"
    sudo chmod 700 "/home/$CODEX_RUNNER_USER/.ssh"
    sudo chmod 600 "/home/$CODEX_RUNNER_USER/.ssh/authorized_keys"
}

codex_env_build_ssh_gateway()
{
    local allowed_pattern
    allowed_pattern="$(codex_env_allowed_pattern)"

    sudo install -o root -g root -m 0755 /dev/stdin "$CODEX_SSH_GATEWAY" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail

read -r -a argv <<< "\${SSH_ORIGINAL_COMMAND:-}"
cmd="\${argv[0]:-}"
args=()
if [[ \${#argv[@]} -gt 1 ]]; then
  args=("\${argv[@]:1}")
fi

case "\$cmd" in
  $allowed_pattern)
    sudo "$CODEX_DEVCTL" "\$cmd" "\${args[@]}"
    ;;
  *)
    echo "Denied SSH command: \${SSH_ORIGINAL_COMMAND:-}" >&2
    exit 2
    ;;
esac
SCRIPT
}

codex_env_force_ssh_gateway()
{
    local pubkey
    pubkey="$(cat "$CODEX_KEY.pub")"

    echo "command=\"$CODEX_SSH_GATEWAY\",no-agent-forwarding,no-X11-forwarding,no-pty $pubkey" \
        | sudo tee "/home/$CODEX_RUNNER_USER/.ssh/authorized_keys" >/dev/null

    sudo chown "$CODEX_RUNNER_USER:$CODEX_RUNNER_USER" "/home/$CODEX_RUNNER_USER/.ssh/authorized_keys"
    sudo chmod 600 "/home/$CODEX_RUNNER_USER/.ssh/authorized_keys"
    sudo chmod 700 "/home/$CODEX_RUNNER_USER/.ssh"
}

codex_env_mount_ssh_key()
{
    local codex_home="/home/codex"
    local ssh_dir="$codex_home/.ssh"

    if [[ ! -f "$CODEX_KEY" ]]; then
        echo "Missing private key: $CODEX_KEY" >&2
        echo "Run codex_env_build_ssh_bridge first." >&2
        return 1
    fi

    sudo docker exec -u 0 "$CODEX_CONTAINER" mkdir -p "$ssh_dir"
    sudo docker cp "$CODEX_KEY" "$CODEX_CONTAINER:$ssh_dir/id_ed25519"

    local container_uid
    local container_gid
    container_uid="$(sudo docker exec "$CODEX_CONTAINER" id -u)"
    container_gid="$(sudo docker exec "$CODEX_CONTAINER" id -g)"

    sudo docker exec -u 0 "$CODEX_CONTAINER" chown -R "$container_uid:$container_gid" "$ssh_dir"
    sudo docker exec "$CODEX_CONTAINER" chmod 700 "$ssh_dir"
    sudo docker exec "$CODEX_CONTAINER" chmod 600 "$ssh_dir/id_ed25519"
    sudo docker exec "$CODEX_CONTAINER" sh -lc "ssh-keyscan '$CODEX_RUNNER_HOST' >> '$ssh_dir/known_hosts'"
    sudo docker exec "$CODEX_CONTAINER" chmod 600 "$ssh_dir/known_hosts"
}

codex_env_build_capability_gated_command_bridge()
{
    codex_env_install_host_devctl
    codex_env_install_devctl_sudoers
    codex_env_create_codex_side_devctl
    codex_env_build_ssh_bridge
    codex_env_build_ssh_gateway
    codex_env_force_ssh_gateway
    codex_env_install_runner_devctl_sudoers
    codex_env_mount_ssh_key
}
