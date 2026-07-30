#!/usr/bin/env bash
# Runtime dependency probes. Prints one line per check and exits non-zero if
# any check fails.
set -uo pipefail

APP_HOME="${DIVEFUZZ_HOME:-/opt/DiveFuzz}"
fail=0

check() {
    local label="$1"; shift
    if out=$("$@" 2>&1); then
        printf 'PASS  %-42s %s\n' "${label}" "$(printf '%s' "${out}" | head -1)"
    else
        printf 'FAIL  %-42s %s\n' "${label}" "$(printf '%s' "${out}" | head -1)"
        fail=1
    fi
}

echo "=== DiveFuzz container dependency probes ==="

check "python --version"        python --version
check "python3.10+ required"    python -c 'import sys; assert sys.version_info >= (3,10), sys.version; print("ok", sys.version.split()[0])'
check "python imports"          python -c 'import yaml, numpy, psutil, tqdm, matplotlib, pybind11; print("yaml", yaml.__version__, "numpy", numpy.__version__)'

for tool in riscv64-unknown-elf-as riscv64-unknown-elf-gcc \
            riscv64-unknown-elf-ld riscv64-unknown-elf-objcopy; do
    check "${tool}" "${tool}" --version
done

check "command -v spike"        command -v spike
check "spike env var set"       bash -c '[ -n "${spike:-}" ] && echo "$spike"'
check "spike env path exists"   bash -c '[ -x "${spike:-}" ] && echo "executable"'
# divefuzz_adapter.py warns when this substring is missing; assert it is not.
check "spike env contains DiveFuzz" bash -c 'case "${spike:-}" in *DiveFuzz*) echo "ok";; *) echo "missing"; exit 1;; esac'

# Spike shells out to dtc at runtime; missing it breaks dive_enable generation.
check "dtc (needed by spike at runtime)" dtc --version

check "import spike_engine"     python -c 'import spike_engine; print(spike_engine.__file__)'
check "instr_dict.json present" bash -c "test -s '${APP_HOME}/fuzzer/generator/reg_analyzer/riscv-opcodes/instr_dict.json' && echo present"
check "run_dut.py --help"       bash -c "python '${APP_HOME}/fuzzer/run_dut.py' --help >/dev/null && echo ok"

echo "=== probes done (fail=${fail}) ==="
exit "${fail}"
