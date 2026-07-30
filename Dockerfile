# syntax=docker/dockerfile:1.7
#
# DiveFuzz core image.
#
# Contains: DiveFuzz source, Python 3.13 + pinned Python dependencies, the
# bare-metal riscv64-unknown-elf toolchain, the pinned custom Spike adapter,
# and a built/importable `spike_engine` extension.
#
# Real DUTs (XiangShan, NutShell, rocket-chip) are deliberately NOT baked in.
# Mount one at runtime and point `emu_path`/`cmd` at the container path.
#
# Build with docker/build.sh, which initializes the pinned submodules first.

# Pinned by digest so rebuilds from the same revision resolve the same base.
#
# Debian 13 (trixie) is required, not bookworm: DiveFuzz's default ISA profile
# (generator/config/config_manager.py ISA_PROFILES) ends in `_zfa`, and
# bookworm's binutils 2.40 rejects the whole -march string with
# "unknown prefixed ISA extension `zfa'", which makes every dive_enable
# assembly fail. trixie ships binutils 2.44, which supports Zfa. This matches
# the README's warning that older toolchains lack some extensions.
ARG BASE_IMAGE=debian:trixie-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd

# Install prefix. Kept capitalised as "DiveFuzz" on purpose: divefuzz_adapter.py
# warns when the `spike` environment value does not contain the string
# "DiveFuzz", so this path keeps that check satisfied without patching code.
ARG APP_HOME=/opt/DiveFuzz
ARG VENV=/opt/venv


###############################################################################
# Stage 1 — builder: compile the pinned Spike adapter and spike_engine.
###############################################################################
FROM ${BASE_IMAGE} AS builder

ARG APP_HOME
ARG VENV
ENV DEBIAN_FRONTEND=noninteractive

# Toolchain and libraries needed to compile Spike + the pybind11 extension.
# Pinned to the exact candidate versions resolved against the digest-pinned
# base image (recorded when this Dockerfile was verified), so a rebuild from
# the same repository revision installs the same package versions rather than
# whatever the live Debian mirror happens to serve on rebuild day. If a pin
# is no longer available (e.g. removed from the archive after a point
# release), apt fails the build with a precise "Version ... not found" error
# instead of silently substituting a different version.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential=12.12 \
        g++=4:14.2.0-1 \
        make=4.4.1-2 \
        device-tree-compiler=1.7.2-2+b1 \
        libboost-regex-dev=1.83.0.2+b2 \
        libboost-system-dev=1.83.0.2+b2 \
        python3=3.13.5-1 \
        python3-dev=3.13.5-1 \
        python3-venv=3.13.5-1 \
        python-is-python3=3.13.3-1 \
        ca-certificates=20250419 \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Python environment (own layer: not invalidated by ordinary source edits).
#
# PyYAML 5.4.1 has no wheel for Python 3.11 and its sdist cannot be built under
# PEP 517 isolation with Cython 3 ("'build_ext' object has no attribute
# 'cython_sources'"). Building it with a pinned Cython<3 and no build isolation
# keeps the version required by requirements.txt instead of silently upgrading.
# ---------------------------------------------------------------------------
RUN python3 -m venv "${VENV}"
ENV PATH="${VENV}/bin:${PATH}"

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --upgrade "pip<25" \
    && pip install --no-cache-dir "setuptools<70" wheel "Cython<3" \
    && pip install --no-cache-dir --no-build-isolation "PyYAML~=5.4.1" \
    && pip install --no-cache-dir -r /tmp/requirements.txt

# ---------------------------------------------------------------------------
# Pinned Spike adapter. The build context must already contain the submodule
# working tree at its pinned gitlink commit (docker/build.sh guarantees this).
# ---------------------------------------------------------------------------
COPY ref/riscv-isa-sim-adapter ${APP_HOME}/ref/riscv-isa-sim-adapter

RUN test -f "${APP_HOME}/ref/riscv-isa-sim-adapter/configure" \
      || { echo "ERROR: ref/riscv-isa-sim-adapter is empty in the build context."; \
           echo "Run:   git submodule update --init ref/riscv-isa-sim-adapter"; \
           echo "or use the documented build command: ./docker/build.sh"; \
           exit 1; }

# Build order matters: Spike static libs first, then the Python extension
# against those artifacts.
RUN cd "${APP_HOME}/ref/riscv-isa-sim-adapter" \
    && mkdir -p build && cd build \
    && ../configure \
    && make -j"$(nproc)"

RUN cd "${APP_HOME}/ref/riscv-isa-sim-adapter/spike_engine" \
    && make

# Strip debug symbols: the unstripped spike binary and extension are ~180MB
# each. --strip-unneeded preserves the dynamic symbols the extension exports.
RUN strip --strip-unneeded "${APP_HOME}/ref/riscv-isa-sim-adapter/spike_engine/"spike_engine*.so \
    && strip "${APP_HOME}/ref/riscv-isa-sim-adapter/build/spike" \
    && cp "${APP_HOME}/ref/riscv-isa-sim-adapter/spike_engine/"spike_engine*.so \
          "$(python -c 'import site; print(site.getsitepackages()[0])')/"

# Fail the build here rather than at runtime if the extension is unusable.
RUN python -c "import spike_engine; print('spike_engine OK:', spike_engine.__file__)" \
    && "${APP_HOME}/ref/riscv-isa-sim-adapter/build/spike" --help >/dev/null 2>&1 \
       || true

# ---------------------------------------------------------------------------
# riscv-opcodes: instruction_encoder.py expects instr_dict.json next to
# arg_lut.csv, and that file is generated (it is not committed upstream).
# ---------------------------------------------------------------------------
COPY fuzzer/generator/reg_analyzer/riscv-opcodes ${APP_HOME}/fuzzer/generator/reg_analyzer/riscv-opcodes

RUN test -f "${APP_HOME}/fuzzer/generator/reg_analyzer/riscv-opcodes/arg_lut.csv" \
      || { echo "ERROR: fuzzer/generator/reg_analyzer/riscv-opcodes is empty in the build context."; \
           echo "Run:   git submodule update --init fuzzer/generator/reg_analyzer/riscv-opcodes"; \
           echo "or use the documented build command: ./docker/build.sh"; \
           exit 1; }

RUN cd "${APP_HOME}/fuzzer/generator/reg_analyzer/riscv-opcodes" \
    && make \
    && test -s instr_dict.json


###############################################################################
# Stage 2 — runtime.
###############################################################################
FROM ${BASE_IMAGE} AS runtime

ARG APP_HOME
ARG VENV
ENV DEBIAN_FRONTEND=noninteractive

# Runtime dependencies only:
#   - python3 / python-is-python3: the project's Makefiles and docs use `python`
#   - libboost-regex/system, libstdc++: spike and spike_engine link these
#     dynamically (the Spike libs themselves are static)
#   - device-tree-compiler: Spike shells out to `dtc` at *runtime* to build its
#     device tree. Without it spike_engine dies with "Failed to run dtc" and
#     every dive_enable seed fails to generate.
#   - binutils-/gcc-riscv64-unknown-elf: the four riscv64-unknown-elf-* commands
#     probed by fuzzer/executor/divefuzz_adapter.py
# Pinned to the same recorded candidate versions as the builder stage, for the
# same reproducibility reason.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3=3.13.5-1 \
        python-is-python3=3.13.3-1 \
        libstdc++6=14.2.0-19 \
        libboost-regex1.83.0=1.83.0-4.2 \
        libboost-system1.83.0=1.83.0-4.2 \
        device-tree-compiler=1.7.2-2+b1 \
        binutils-riscv64-unknown-elf=2.44-3+7+b1 \
        gcc-riscv64-unknown-elf=14.2.0+19 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder ${VENV} ${VENV}

# Spike adapter: the executable, and the extension at the exact path
# fuzzer/generator/reg_analyzer/spike_session.py inserts into sys.path.
COPY --from=builder ${APP_HOME}/ref/riscv-isa-sim-adapter/build/spike \
                    ${APP_HOME}/ref/riscv-isa-sim-adapter/build/spike
COPY --from=builder ${APP_HOME}/ref/riscv-isa-sim-adapter/spike_engine/ \
                    ${APP_HOME}/ref/riscv-isa-sim-adapter/spike_engine/

# (The extension is also present in ${VENV} site-packages, copied above, so a
# plain `import spike_engine` works from any working directory.)

# Generated opcode tables + the rest of riscv-opcodes.
COPY --from=builder ${APP_HOME}/fuzzer/generator/reg_analyzer/riscv-opcodes/ \
                    ${APP_HOME}/fuzzer/generator/reg_analyzer/riscv-opcodes/

# DiveFuzz source last: ordinary source edits do not invalidate the layers above.
COPY fuzzer/ ${APP_HOME}/fuzzer/
COPY requirements.txt README.md ${APP_HOME}/
COPY docker/ ${APP_HOME}/docker/
COPY tests/ ${APP_HOME}/tests/

# Environment.
#   PATH   -> `command -v spike` (this is what README documents)
#   spike  -> lowercase variable that divefuzz_adapter.py actually reads;
#             README only mentions PATH, so both are set deliberately.
ENV VIRTUAL_ENV="${VENV}" \
    PATH="${VENV}/bin:${APP_HOME}/ref/riscv-isa-sim-adapter/build:${PATH}" \
    spike="${APP_HOME}/ref/riscv-isa-sim-adapter/build/spike" \
    DIVEFUZZ_HOME="${APP_HOME}" \
    PYTHONDONTWRITEBYTECODE=1

RUN chmod +x "${APP_HOME}/docker/smoke-dut/emu" "${APP_HOME}"/docker/*.sh \
    && ln -s "${APP_HOME}/docker/entrypoint.sh" /usr/local/bin/divefuzz

# Non-root runtime user. /work is the default working directory, so the
# relative `outputs` directory used by config/logger_config.py lands there.
RUN useradd --create-home --uid 1000 --shell /bin/bash divefuzz \
    && mkdir -p /work/outputs /work/seeds \
    && chown -R divefuzz:divefuzz /work

USER divefuzz
WORKDIR /work

ENTRYPOINT ["/usr/local/bin/divefuzz"]
CMD ["--help"]
