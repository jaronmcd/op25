#!/usr/bin/with-contenv bashio
set -euo pipefail

bashio::log.info "[STARTUP] OP25 add-on starting..."

WORKDIR="$(bashio::config 'workdir')"
HTTP_HOST="$(bashio::config 'http_host')"
HTTP_PORT="$(bashio::config 'http_port')"
RX_ARGS_RAW="$(bashio::config 'rx_args')"

# Ensure workdir exists (commonly /share/op25)
mkdir -p "${WORKDIR}"

# Helpful check: if user is using -T, ensure the file exists.
# (We don't try to parse all args; just a best-effort warning.)
if echo " ${RX_ARGS_RAW} " | grep -q " -T "; then
  # naive extraction of the next token after -T
  TSV_PATH="$(printf '%s\n' "${RX_ARGS_RAW}" | awk '{for(i=1;i<=NF;i++){if($i=="-T"){print $(i+1); exit}}}')"
  if [[ -n "${TSV_PATH}" ]]; then
    # Allow relative path (relative to workdir)
    if [[ "${TSV_PATH}" != /* ]]; then
      TSV_PATH="${WORKDIR%/}/${TSV_PATH}"
    fi
    if [[ ! -f "${TSV_PATH}" ]]; then
      bashio::log.warning "[CONFIG] trunk TSV not found: ${TSV_PATH}"
      bashio::log.warning "[CONFIG] Put your trunk.tsv in /share/op25 (or update rx_args)."
    fi
  fi
fi

# Build the final argument list.
# If user already provided '-l ...' in rx_args, don't append another.
RX_ARGS_FINAL="${RX_ARGS_RAW}"
if ! echo " ${RX_ARGS_RAW} " | grep -q " -l "; then
  RX_ARGS_FINAL="${RX_ARGS_FINAL} -l http:${HTTP_HOST}:${HTTP_PORT}"
fi

# OP25 expects to be run from the apps directory so it can find relative assets.
APPS_DIR="/opt/op25/op25/gr-op25_repeater/apps"
if [[ ! -d "${APPS_DIR}" ]]; then
  bashio::log.error "[FATAL] OP25 apps directory not found at ${APPS_DIR}. Build/install likely failed."
  exit 1
fi

cd "${APPS_DIR}"

# Some helper scripts read op25_python; set it defensively.
echo "/usr/bin/python3" > op25_python || true

bashio::log.info "[RUN] python3 ./rx.py ${RX_ARGS_FINAL}"
exec python3 ./rx.py ${RX_ARGS_FINAL}
