#!/usr/bin/env bash
# DiveFuzz container entrypoint.
#
#   <no args> | --help | --config X   -> fuzzer/run_dut.py
#   probe                             -> runtime dependency probes
#   smoke                             -> end-to-end smoke test
#   anything else                     -> executed verbatim (bash, python, ...)
set -euo pipefail

APP_HOME="${DIVEFUZZ_HOME:-/opt/DiveFuzz}"

case "${1:-}" in
    "")
        exec python "${APP_HOME}/fuzzer/run_dut.py" --help
        ;;
    -*)
        exec python "${APP_HOME}/fuzzer/run_dut.py" "$@"
        ;;
    probe)
        exec "${APP_HOME}/docker/probe.sh"
        ;;
    smoke)
        shift
        exec "${APP_HOME}/docker/smoke-test.sh" "$@"
        ;;
    *)
        exec "$@"
        ;;
esac
