#!/usr/bin/env bash
set -euo pipefail

# Installs /usr/local/bin/codex-devctl, the host-side command allowlist.
# Customize this file per project. Keep command names synchronized with
# CODEX_ALLOWED_COMMANDS in helper_script.sh.

DEFAULT_PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_DIR="${CODEX_PROJECT_DIR:-$DEFAULT_PROJECT_DIR}"
INSTALL_PATH="${CODEX_DEVCTL:-/usr/local/bin/codex-devctl}"

install -o root -g root -m 0755 /dev/stdin "$INSTALL_PATH" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR}"
FRONTEND_DIR="\${CODEX_FRONTEND_DIR:-\$PROJECT_DIR/frontend}"
API_DIR="\${CODEX_API_DIR:-\$PROJECT_DIR/api}"
COMPOSE_FILE="\${CODEX_COMPOSE_FILE:-\$PROJECT_DIR/docker-compose.yml}"

FRONT_CONTAINER="\${CODEX_FRONT_CONTAINER:-front}"
API_CONTAINER="\${CODEX_API_CONTAINER:-api}"
DB_CONTAINER="\${CODEX_DB_CONTAINER:-db}"
FRONT_PORT="\${CODEX_FRONT_PORT:-3000}"
API_PORT="\${CODEX_API_PORT:-3000}"
FRONT_HOST_PORT="\${CODEX_FRONT_HOST_PORT:-\$FRONT_PORT}"
API_HOST_PORT="\${CODEX_API_HOST_PORT:-\$API_PORT}"
FIND_DEPTH="\${CODEX_FIND_DEPTH:-3}"

cmd="\${1:-}"
shift || true

require_dir()
{
  if [[ ! -d "\$1" ]]; then
    echo "Missing directory: \$1" >&2
    exit 2
  fi
}

require_file()
{
  if [[ ! -f "\$1" ]]; then
    echo "Missing file: \$1" >&2
    exit 2
  fi
}

resolve_container()
{
  case "\${1:-}" in
    front|frontend|"\$FRONT_CONTAINER") echo "\$FRONT_CONTAINER" ;;
    api|rest|backend|"\$API_CONTAINER") echo "\$API_CONTAINER" ;;
    db|database|mysql|postgres|"\$DB_CONTAINER") echo "\$DB_CONTAINER" ;;
    *)
      echo "Denied container: \${1:-}" >&2
      echo "Allowed containers: front, api, db" >&2
      exit 2
      ;;
  esac
}

resolve_http_target()
{
  case "\${1:-}" in
    front|frontend|"\$FRONT_CONTAINER"|"\$FRONT_CONTAINER:\$FRONT_PORT")
      echo "127.0.0.1:\$FRONT_HOST_PORT"
      ;;
    api|rest|backend|"\$API_CONTAINER"|"\$API_CONTAINER:\$API_PORT")
      echo "127.0.0.1:\$API_HOST_PORT"
      ;;
    http://*|https://*)
      echo "\${1:-}"
      ;;
    *)
      echo "\${1:-}"
      ;;
  esac
}

run_compose()
{
  require_file "\$COMPOSE_FILE"
  docker compose -f "\$COMPOSE_FILE" "\$@"
}

case "\$cmd" in
  project-status)
    cd "\$PROJECT_DIR"
    git status --short
    ;;

  project-diff)
    cd "\$PROJECT_DIR"
    git diff --stat
    ;;

  project-files)
    find "\$PROJECT_DIR" -maxdepth "\$FIND_DEPTH" -type f | sort
    ;;

  ps)
    docker ps \
      --filter "name=\$FRONT_CONTAINER" \
      --filter "name=\$API_CONTAINER" \
      --filter "name=\$DB_CONTAINER"
    ;;

  logs)
    target="\$(resolve_container "\${1:?container alias required: front, api, db}")"
    docker logs --tail="\${2:-200}" "\$target"
    ;;

  ip)
    target="\$(resolve_container "\${1:-api}")"
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "\$target"
    ;;

  smoke-url)
    target="\$(resolve_http_target "\${1:?URL, alias, or host:port required}")"
    case "\$target" in
      http://*|https://*) url="\$target" ;;
      *) url="http://\$target" ;;
    esac
    curl -I "\$url"
    ;;

  compose-ps)
    run_compose ps
    ;;

  compose-up)
    run_compose up -d
    ;;

  compose-down)
    run_compose down
    ;;

  front-lint)
    require_dir "\$FRONTEND_DIR"
    cd "\$FRONTEND_DIR"
    npm run lint
    ;;

  front-typecheck)
    require_dir "\$FRONTEND_DIR"
    cd "\$FRONTEND_DIR"
    npx tsc --noEmit
    ;;

  front-build)
    require_dir "\$FRONTEND_DIR"
    cd "\$FRONTEND_DIR"
    npm run build
    ;;

  front-test)
    require_dir "\$FRONTEND_DIR"
    cd "\$FRONTEND_DIR"
    npm test
    ;;

  api-build)
    require_dir "\$API_DIR"
    cd "\$API_DIR"
    cmake -S . -B build
    cmake --build build
    ;;

  api-test)
    require_dir "\$API_DIR"
    cd "\$API_DIR"
    ctest --test-dir build --output-on-failure
    ;;

  *)
    echo "Denied command: \$cmd" >&2
    echo "Allowed: project-status project-diff project-files ps logs ip smoke-url compose-ps compose-up compose-down front-lint front-typecheck front-build front-test api-build api-test" >&2
    exit 2
    ;;
esac
SCRIPT

echo "Installed host devctl: $INSTALL_PATH"
