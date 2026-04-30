#!/bin/sh
set -eu

# Defense-in-depth: scrub environment of anything not allowlisted.
# Secrets arrive via /run/secrets/ files (Docker Compose secrets),
# never as environment variables.

SAFE_VARS="HOME USER PATH HOSTNAME TERM LANG LC_ALL \
  LLM_PROXY_URL PYTHONDONTWRITEBYTECODE PYTHONUNBUFFERED \
  HF_HOME SENTENCE_TRANSFORMERS_HOME OMEGACLAW_DIR MEMORY_DIR"

env_args=""
for var in $SAFE_VARS; do
  eval val=\${$var:-}
  if [ -n "$val" ]; then
    env_args="$env_args $var=$val"
  fi
done

exec env -i $env_args sh run.sh "$@"
