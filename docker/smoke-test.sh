#!/usr/bin/env bash
# End-to-end DiveFuzz smoke test, run entirely inside the container.
#
# It exercises the real pipeline: seed generation -> assembly -> ELF -> IMG
# conversion -> DUT execution through dut_executor.py's `$1` substitution and
# emu_path working directory. The DUT is the smoke fixture, so this proves
# container plumbing, NOT CPU correctness.
#
# Usage:  smoke-test.sh [--no-dive]
#   default    dive_enable: true  (exercises spike_engine diversification)
#   --no-dive  dive_enable: false (generation without spike_engine)
set -uo pipefail

APP_HOME="${DIVEFUZZ_HOME:-/opt/DiveFuzz}"
WORK="${PWD}"
CONFIG_SRC="${APP_HOME}/docker/divefuzz-smoke.yaml"

use_dive=1
[ "${1:-}" = "--no-dive" ] && use_dive=0

echo "=== DiveFuzz container smoke test ==="
echo "workdir: ${WORK}   dive_enable: ${use_dive}"

# run_dut.py resolves `outputs` relative to the cwd and the config stem becomes
# part of every log filename, so keep the config next to the outputs.
CONFIG="${WORK}/divefuzz-smoke.yaml"
if [ "${use_dive}" -eq 1 ]; then
    cp "${CONFIG_SRC}" "${CONFIG}"
else
    sed 's/dive_enable: true/dive_enable: false/' "${CONFIG_SRC}" > "${CONFIG}"
fi

# Start from a clean slate so the assertions below cannot pass on stale files.
rm -rf "${WORK}/seeds" "${WORK}/outputs"
mkdir -p "${WORK}/seeds" "${WORK}/outputs"

echo
echo "--- running DiveFuzz ---"
python "${APP_HOME}/fuzzer/run_dut.py" --config "${CONFIG}"
run_rc=$?
echo "--- run_dut.py exit code: ${run_rc} ---"
echo

fail=0
note() { printf '%-6s %s\n' "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }

# --- 1. generated assembly -------------------------------------------------
asm_count=$(find "${WORK}/seeds" -maxdepth 1 -name '*.S' -size +0c | wc -l | tr -d ' ')
if [ "${asm_count}" -ge 1 ]; then
    note PASS "generated ${asm_count} non-empty .S assembly seed(s)"
else
    note FAIL "no non-empty .S files in ${WORK}/seeds"
fi

# --- 2. ELF conversion (real project pipeline) -----------------------------
elf_count=$(find "${WORK}/seeds/elf_file" -maxdepth 1 -name '*.elf' -size +0c 2>/dev/null | wc -l | tr -d ' ')
if [ "${elf_count}" -ge 1 ]; then
    note PASS "converted ${elf_count} non-empty .elf file(s)"
else
    note FAIL "no non-empty .elf files in ${WORK}/seeds/elf_file"
fi

# --- 3. IMG conversion (the format handed to the DUT) ----------------------
img_count=$(find "${WORK}/seeds/img_file" -maxdepth 1 -name '*.img' -size +0c 2>/dev/null | wc -l | tr -d ' ')
if [ "${img_count}" -ge 1 ]; then
    note PASS "converted ${img_count} non-empty .img seed(s)"
else
    note FAIL "no non-empty .img files in ${WORK}/seeds/img_file"
fi

# --- 4. persistent logs ----------------------------------------------------
log_count=$(find "${WORK}/outputs" -name 'divefuzz-smoke-*.log' -size +0c | wc -l | tr -d ' ')
if [ "${log_count}" -ge 1 ]; then
    note PASS "wrote ${log_count} non-empty log file(s) to ${WORK}/outputs"
else
    note FAIL "no non-empty logs in ${WORK}/outputs"
fi

# --- 5. the DUT actually ran, via $1 substitution and emu_path cwd ---------
# The fixture only prints this after verifying cwd, $1 and a non-empty seed.
ok_runs=$(grep -rl 'smoke-dut: OK' "${WORK}/outputs" 2>/dev/null | wc -l | tr -d ' ')
if [ "${ok_runs}" -ge 1 ]; then
    note PASS "smoke DUT executed successfully for ${ok_runs} seed log(s)"
else
    note FAIL "no log contains 'smoke-dut: OK' (DUT never ran, or \$1/emu_path wrong)"
fi

# The fixture echoes its cwd; it must equal the configured emu_path.
if grep -rq 'smoke-dut: cwd=/opt/DiveFuzz/docker/smoke-dut' "${WORK}/outputs" 2>/dev/null; then
    note PASS "DUT ran with cwd == emu_path"
else
    note FAIL "DUT cwd did not match emu_path"
fi

# The substituted seed path must be the .img produced above.
if grep -rq 'smoke-dut: seed=/work/seeds/img_file/.*\.img' "${WORK}/outputs" 2>/dev/null; then
    note PASS "\$1 was substituted with the generated .img path"
else
    note FAIL "\$1 substitution did not yield a generated .img path"
fi

# --- 6. no failed / errored seeds -----------------------------------------
if grep -rqE 'Status: (FAILURE|ERROR|TIMEOUT)' "${WORK}/outputs" 2>/dev/null; then
    note FAIL "at least one seed reported FAILURE/ERROR/TIMEOUT"
else
    note PASS "no seed reported FAILURE/ERROR/TIMEOUT"
fi

# --- 7. spike_engine actually used, when --dive ---------------------------
if [ "${use_dive}" -eq 1 ]; then
    if python -c 'import spike_engine' 2>/dev/null; then
        note PASS "spike_engine importable for dive run"
    else
        note FAIL "spike_engine not importable"
    fi
fi

echo
if [ "${fail}" -eq 0 ]; then
    echo "=== SMOKE TEST PASSED ==="
    echo "seeds: ${WORK}/seeds   logs: ${WORK}/outputs"
else
    echo "=== SMOKE TEST FAILED ==="
fi
exit "${fail}"
