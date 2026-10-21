#!/usr/bin/env bash
# Installs the OpenTelemetry Collector as a host agent on a Linux server (systemd).
#
#   sudo bash scripts/install-otel-agent.sh --gateway otel-gateway.example.org:4317 --environment production
#
# Safe to run again: the binary is only downloaded when the version changes, and the
# service is restarted only after the new configuration has been validated.

set -euo pipefail

VERSION=0.135.0
GATEWAY=""
ENVIRONMENT=production
CONFIG_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/otel/agent.yaml"
DRY_RUN=false
START_SERVICE=true

BIN=/usr/local/bin/otelcol-contrib
CONFIG_DIR=/etc/otelcol-contrib
SERVICE_USER=otelcol
UNIT=/etc/systemd/system/otelcol-contrib.service
RELEASES=https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download

usage() {
    cat <<USAGE
Usage: $0 --gateway HOST:PORT [options]

  --gateway HOST:PORT    OTLP/gRPC endpoint of the central gateway (required)
  --environment NAME     value of deployment.environment.name (default: $ENVIRONMENT)
  --version X.Y.Z        collector version (default: $VERSION)
  --config FILE          agent configuration (default: otel/agent.yaml of this repository)
  --no-start             install and validate only, do not touch systemd (images, containers)
  --dry-run              print what would be done, change nothing
USAGE
}

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# run a command, or only print it in dry-run mode
run() {
    if $DRY_RUN; then
        printf '    [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

parse_args() {
    while (($# > 0)); do
        case $1 in
            --gateway) GATEWAY=${2:?--gateway needs a value}; shift 2 ;;
            --environment) ENVIRONMENT=${2:?--environment needs a value}; shift 2 ;;
            --version) VERSION=${2:?--version needs a value}; shift 2 ;;
            --config) CONFIG_SOURCE=${2:?--config needs a value}; shift 2 ;;
            --no-start) START_SERVICE=false; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            -h | --help) usage; exit 0 ;;
            *) usage >&2; die "unknown option: $1" ;;
        esac
    done
    [[ -n $GATEWAY ]] || { usage >&2; die "--gateway is required"; }
    [[ $GATEWAY =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || die "--gateway must look like host:port, got '$GATEWAY'"
    [[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--version must look like 0.135.0, got '$VERSION'"
    [[ -f $CONFIG_SOURCE ]] || die "configuration not found: $CONFIG_SOURCE"
}

check_system() {
    [[ $(uname -s) == Linux ]] || die "this script is for Linux servers"
    if ! $DRY_RUN && ((EUID != 0)); then
        die "run as root (sudo), or use --dry-run"
    fi
    for tool in curl tar sha256sum install; do
        command -v "$tool" >/dev/null || die "$tool is required"
    done
    if $START_SERVICE && ! command -v systemctl >/dev/null; then
        die "systemd not found: use --no-start and start the collector another way"
    fi

    case $(uname -m) in
        x86_64) ARCH=amd64 ;;
        aarch64 | arm64) ARCH=arm64 ;;
        *) die "unsupported architecture: $(uname -m)" ;;
    esac
}

installed_version() {
    [[ -x $BIN ]] && "$BIN" --version 2>/dev/null | awk '{print $NF}'
}

install_binary() {
    if [[ $(installed_version || true) == "$VERSION" ]]; then
        log "otelcol-contrib $VERSION already installed"
        return
    fi

    local archive="otelcol-contrib_${VERSION}_linux_${ARCH}.tar.gz"
    local tmp=$WORK_DIR

    log "downloading $archive"
    run curl -fsSL -o "$tmp/$archive" "$RELEASES/v$VERSION/$archive"
    run curl -fsSL -o "$tmp/checksums.txt" "$RELEASES/v$VERSION/opentelemetry-collector-releases_otelcol-contrib_checksums.txt"

    log "verifying checksum"
    if ! $DRY_RUN; then
        (cd "$tmp" && grep " ${archive}\$" checksums.txt | sha256sum --check --status) ||
            die "checksum mismatch for $archive"
    fi

    run tar -xzf "$tmp/$archive" -C "$tmp" otelcol-contrib
    run install -m 0755 "$tmp/otelcol-contrib" "$BIN"
}

create_user() {
    if id "$SERVICE_USER" >/dev/null 2>&1; then
        return
    fi
    log "creating system user $SERVICE_USER"
    run useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
}

write_config() {
    log "writing configuration to $CONFIG_DIR"
    run install -d -m 0755 "$CONFIG_DIR"
    run install -m 0644 "$CONFIG_SOURCE" "$CONFIG_DIR/config.yaml"

    local env_file="$CONFIG_DIR/otelcol.env"
    if $DRY_RUN; then
        printf '    [dry-run] write %s (gateway %s, environment %s)\n' "$env_file" "$GATEWAY" "$ENVIRONMENT"
    else
        cat >"$env_file" <<ENV
# Managed by install-otel-agent.sh
OTEL_GATEWAY_ENDPOINT=$GATEWAY
DEPLOYMENT_ENVIRONMENT=$ENVIRONMENT
HOST_ROOT_PATH=/
ENV
        chown "root:$SERVICE_USER" "$env_file"
        chmod 0640 "$env_file"
    fi
}

validate_config() {
    log "validating configuration"
    $DRY_RUN && return
    (
        set -a
        # shellcheck source=/dev/null
        . "$CONFIG_DIR/otelcol.env"
        "$BIN" validate --config "$CONFIG_DIR/config.yaml"
    ) || die "invalid configuration, the running service was left unchanged"
}

write_unit() {
    log "installing systemd unit"
    if $DRY_RUN; then
        printf '    [dry-run] write %s\n' "$UNIT"
        return
    fi
    cat >"$UNIT" <<UNIT
[Unit]
Description=OpenTelemetry Collector (host agent)
Documentation=https://opentelemetry.io/docs/collector/
After=network-online.target
Wants=network-online.target

[Service]
User=$SERVICE_USER
Group=$SERVICE_USER
EnvironmentFile=$CONFIG_DIR/otelcol.env
ExecStart=$BIN --config $CONFIG_DIR/config.yaml
Restart=on-failure
RestartSec=5

# the agent only needs to read /proc and the file systems
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
MemoryMax=512M

[Install]
WantedBy=multi-user.target
UNIT
}

start_service() {
    if ! $START_SERVICE; then
        log "--no-start: not touching systemd"
        return
    fi
    log "starting otelcol-contrib"
    run systemctl daemon-reload
    run systemctl enable otelcol-contrib
    run systemctl restart otelcol-contrib

    $DRY_RUN && return
    for _ in $(seq 1 15); do
        if curl -fsS http://localhost:13133/ >/dev/null 2>&1; then
            log "agent is healthy, sending to $GATEWAY"
            return
        fi
        sleep 2
    done
    systemctl --no-pager status otelcol-contrib || true
    die "agent did not become healthy, see: journalctl -u otelcol-contrib"
}

main() {
    parse_args "$@"
    check_system
    WORK_DIR=$(mktemp -d)
    trap 'rm -rf "$WORK_DIR"' EXIT
    $DRY_RUN && log "dry run: nothing will be changed"
    install_binary
    create_user
    write_config
    validate_config
    write_unit
    start_service
}

main "$@"
