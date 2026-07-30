#!/usr/bin/env bash
# Documented build command for the DiveFuzz core image.
#
# Initializes exactly the pinned submodules the image needs (at their recorded
# gitlink commits, never a floating branch), then builds the image.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${DIVEFUZZ_IMAGE:-divefuzz:latest}"

# Only these two submodules are required by the image. dut/* (XiangShan,
# NutShell, rocket-chip) and ref/riscv-isa-sim are deliberately left alone.
REQUIRED_SUBMODULES=(
    "ref/riscv-isa-sim-adapter"
    "fuzzer/generator/reg_analyzer/riscv-opcodes"
)

cd "${REPO_ROOT}"

if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git is required to initialize the pinned submodules." >&2
    exit 1
fi

echo "==> Initializing pinned submodules"
if ! git submodule update --init "${REQUIRED_SUBMODULES[@]}"; then
    echo >&2
    echo "ERROR: could not initialize the pinned submodules." >&2
    echo "       This build needs network access to GitHub for:" >&2
    for sm in "${REQUIRED_SUBMODULES[@]}"; do
        echo "         - ${sm}" >&2
    done
    echo "       Fix connectivity (or clone with --recurse-submodules) and retry." >&2
    exit 1
fi

# Fail early and precisely rather than deep inside the image build.
for sm in "${REQUIRED_SUBMODULES[@]}"; do
    if [ -z "$(ls -A "${sm}" 2>/dev/null)" ]; then
        echo "ERROR: submodule '${sm}' is still empty after init." >&2
        echo "       Run: git submodule update --init ${sm}" >&2
        exit 1
    fi
done

echo "==> Pinned submodule commits"
git submodule status "${REQUIRED_SUBMODULES[@]}"

echo "==> Building ${IMAGE}"
docker build -t "${IMAGE}" "$@" .

echo
echo "Built ${IMAGE}"
echo "Next: ./docker/smoke-test-host.sh"
