#!/bin/sh
set -eu

# Read auth secret from Docker secret (root-owned, mode 0400) or env var
# fallback, then hand it off as an ephemeral temp file owned by the
# unprivileged runtime user.  Python reads and deletes the file at startup.
AUTH_SECRET_FILE="/run/secrets/omegaclaw_auth_secret"
if [ -f "$AUTH_SECRET_FILE" ]; then
    secret=$(cat "$AUTH_SECRET_FILE")
    if [ -n "$secret" ]; then
        printf '%s' "$secret" > /tmp/.auth_secret
        chown 65534:65534 /tmp/.auth_secret
        chmod 0400 /tmp/.auth_secret
    fi
elif [ -n "${OMEGACLAW_AUTH_SECRET:-}" ]; then
    printf '%s' "$OMEGACLAW_AUTH_SECRET" > /tmp/.auth_secret
    chown 65534:65534 /tmp/.auth_secret
    chmod 0400 /tmp/.auth_secret
fi

# Scrub environment: only allowlisted vars survive into the main process.
# Channel tokens live in the proxy container, not here.
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

exec setpriv --reuid=65534 --regid=65534 --init-groups \
  env -i $env_args sh run.sh "$@"
