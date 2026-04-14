#!/usr/bin/env bash
#
# Local build loop for ZMK firmware using Docker.
# Uses zmkfirmware/zmk-build-arm:stable — no local toolchain needed.
#
# Usage:
#   ./build.sh              # build both halves
#   ./build.sh left         # build left only
#   ./build.sh right        # build right only
#   ./build.sh clean        # wipe cached west workspace
#   ./build.sh studio       # build left with ZMK Studio support
#
# Firmware output: ./firmware/*.uf2
#
set -euo pipefail

DOCKER_IMAGE="zmkfirmware/zmk-build-arm:stable"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/.build_cache"
FIRMWARE_DIR="${SCRIPT_DIR}/firmware"

# Board identifiers (HWMv2 format)
BOARD_LEFT="eyelash_sofle_left/nrf52840"
BOARD_RIGHT="eyelash_sofle_right/nrf52840"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}▸${NC} $*"; }
ok()   { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
err()  { echo -e "${RED}✖${NC} $*" >&2; }

usage() {
    sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \?//'
    exit 0
}

# ── arg parse ──────────────────────────────────────────────────────
TARGET="${1:-all}"
case "$TARGET" in
    -h|--help|help) usage ;;
    clean)
        log "Removing cached west workspace…"
        rm -rf "$CACHE_DIR"
        ok "Clean complete."
        exit 0
        ;;
    left|right|all|studio) ;;
    *)
        err "Unknown target: $TARGET"
        usage
        ;;
esac

# ── preflight ──────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    err "Docker is required but not found. Install Docker Desktop first."
    exit 1
fi

if ! docker info &>/dev/null 2>&1; then
    err "Docker daemon is not running. Start Docker Desktop first."
    exit 1
fi

# Pull image if not present
if ! docker image inspect "$DOCKER_IMAGE" &>/dev/null 2>&1; then
    log "Pulling $DOCKER_IMAGE (first run only)…"
    docker pull "$DOCKER_IMAGE"
fi

mkdir -p "$CACHE_DIR" "$FIRMWARE_DIR"

# ── west workspace init (cached) ──────────────────────────────────
init_workspace() {
    if [ ! -f "$CACHE_DIR/.west/config" ]; then
        log "Initializing west workspace (first run, may take a few minutes)…"
        docker run --rm \
            -v "$SCRIPT_DIR":/zmk-config:ro \
            -v "$CACHE_DIR":/workspace \
            -w /workspace \
            "$DOCKER_IMAGE" \
            sh -c '
                cp -r /zmk-config/config ./config &&
                west init -l config &&
                find . -name "index.lock" -delete 2>/dev/null;
                west update --fetch-opt=--filter=tree:0 ||
                  { find . -name "index.lock" -delete; west update --fetch-opt=--filter=tree:0; } &&
                west zephyr-export
            '
        ok "West workspace initialized and cached."
    else
        log "Updating west workspace…"
        docker run --rm \
            -v "$SCRIPT_DIR":/zmk-config:ro \
            -v "$CACHE_DIR":/workspace \
            -w /workspace \
            "$DOCKER_IMAGE" \
            sh -c '
                cp -r /zmk-config/config/* ./config/ &&
                find . -name "index.lock" -delete 2>/dev/null;
                west update --fetch-opt=--filter=tree:0 ||
                  { find . -name "index.lock" -delete; west update --fetch-opt=--filter=tree:0; } &&
                west zephyr-export
            '
        ok "West workspace updated."
    fi
}

# ── build one target ──────────────────────────────────────────────
build_target() {
    local board="$1"
    local artifact_name="$2"
    local extra_cmake="${3:-}"
    local extra_west="${4:-}"
    local build_dir="/workspace/build/${artifact_name}"

    log "Building ${YELLOW}${artifact_name}${NC}  (board=${board})"

    docker run --rm \
        -v "$SCRIPT_DIR":/zmk-config:ro \
        -v "$CACHE_DIR":/workspace \
        -v "$FIRMWARE_DIR":/firmware \
        -w /workspace \
        "$DOCKER_IMAGE" \
        sh -c "
            west zephyr-export 2>/dev/null &&
            west build -s zmk/app -d '${build_dir}' -b '${board}' ${extra_west} -p auto \
                -- -DZMK_CONFIG=/workspace/config \
                   -DZMK_EXTRA_MODULES=/zmk-config \
                   ${extra_cmake} &&
            if [ -f '${build_dir}/zephyr/zmk.uf2' ]; then
                cp '${build_dir}/zephyr/zmk.uf2' '/firmware/${artifact_name}.uf2'
            elif [ -f '${build_dir}/zephyr/zmk.bin' ]; then
                cp '${build_dir}/zephyr/zmk.bin' '/firmware/${artifact_name}.bin'
            fi
        "

    if [ -f "$FIRMWARE_DIR/${artifact_name}.uf2" ]; then
        ok "${artifact_name}.uf2 → firmware/"
    elif [ -f "$FIRMWARE_DIR/${artifact_name}.bin" ]; then
        ok "${artifact_name}.bin → firmware/"
    else
        err "Build produced no firmware output for ${artifact_name}"
        return 1
    fi
}

# ── main ──────────────────────────────────────────────────────────
SECONDS=0

init_workspace

failed=0

case "$TARGET" in
    left)
        build_target "$BOARD_LEFT" "eyelash_sofle_left" || failed=1
        ;;
    right)
        build_target "$BOARD_RIGHT" "eyelash_sofle_right" || failed=1
        ;;
    studio)
        build_target "$BOARD_LEFT" "eyelash_sofle_studio_left" \
            "-DCONFIG_ZMK_STUDIO=y -DCONFIG_ZMK_STUDIO_LOCKING=n" \
            "-S studio-rpc-usb-uart" || failed=1
        ;;
    all)
        build_target "$BOARD_RIGHT" "eyelash_sofle_right" || failed=1
        build_target "$BOARD_LEFT" "eyelash_sofle_left" || failed=1
        ;;
esac

echo ""
if [ "$failed" -eq 0 ]; then
    ok "Done in ${SECONDS}s. Firmware files:"
    ls -lh "$FIRMWARE_DIR"/*.uf2 "$FIRMWARE_DIR"/*.bin 2>/dev/null | awk '{print "   " $NF " (" $5 ")"}'
else
    err "Build failed after ${SECONDS}s."
    exit 1
fi
