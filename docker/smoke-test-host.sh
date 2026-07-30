#!/usr/bin/env bash
# Reproducible host-side wrapper for the end-to-end container smoke test.
#
# Runs the smoke test in a container with a persistent bind mount, then asserts
# from the *host* that the artifacts survived outside the container.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${DIVEFUZZ_IMAGE:-divefuzz:latest}"
OUT_DIR="${DIVEFUZZ_WORKDIR:-${REPO_ROOT}/docker-smoke-out}"

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

echo "==> Running smoke test in ${IMAGE}"
echo "    persistent workdir (host): ${OUT_DIR}"
echo

docker run --rm \
    -v "${OUT_DIR}:/work" \
    "${IMAGE}" smoke "$@"
container_rc=$?

echo
echo "==> Container exit code: ${container_rc}"
echo "==> Host-side artifact verification"

host_fail=0
note() { printf '%-6s %s\n' "$1" "$2"; [ "$1" = "FAIL" ] && host_fail=1; return 0; }

imgs=$(find "${OUT_DIR}/seeds/img_file" -name '*.img' -size +0c 2>/dev/null | wc -l | tr -d ' ')
[ "${imgs}" -ge 1 ] \
    && note PASS "host sees ${imgs} non-empty .img seed(s) in ${OUT_DIR}/seeds/img_file" \
    || note FAIL "no non-empty .img seeds visible on the host"

logs=$(find "${OUT_DIR}/outputs" -name '*.log' -size +0c 2>/dev/null | wc -l | tr -d ' ')
[ "${logs}" -ge 1 ] \
    && note PASS "host sees ${logs} non-empty log(s) in ${OUT_DIR}/outputs" \
    || note FAIL "no non-empty logs visible on the host"

[ "${container_rc}" -eq 0 ] \
    && note PASS "container exited 0" \
    || note FAIL "container exited ${container_rc}"

echo
if [ "${host_fail}" -eq 0 ] && [ "${container_rc}" -eq 0 ]; then
    echo "=== END-TO-END SMOKE TEST PASSED ==="
    exit 0
fi
echo "=== END-TO-END SMOKE TEST FAILED ==="
exit 1
