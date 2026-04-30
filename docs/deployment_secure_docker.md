# Secure Docker Deployment

This guide deploys OmegaClaw with a reverse proxy that hides API keys from
the agent container. Two deployment paths are available: `docker compose`
(recommended for persistent deployments) and `scripts/omegaclaw` (interactive,
for evaluation). An optional restricted mode adds full network isolation.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    external network (internet)               │
│                                                              │
│  ┌───────────┐              ┌──────────────┐  HTTPS          │
│  │ irc-proxy │  TCP         │  gateway     │──TLS────────▸   │
│  │ (socat)   │──────────▸   │  (nginx)     │  LLM + chat +   │
│  └─────┬─────┘              └──────┬───────┘  APIs           │
└────────┼───────────────────────────┼─────────────────────────┘
┌────────┼───────────────────────────┼─────────────────────────┐
│        │    internal network       │                         │
│  ┌─────┴───────────────────────────┴──────┐                  │
│  │            omegaclaw                   │                  │
│  │   NO API keys in environment           │                  │
│  │   Default: full internet access        │                  │
│  │   Restricted: proxy-only access        │                  │
│  └────────────────────────────────────────┘                  │
└──────────────────────────────────────────────────────────────┘
```

**Layer 1 — Reverse proxy.** An nginx reverse proxy holds all API keys,
**channel tokens** (Telegram bot token, Mattermost bot token), **and the
owner auth secret**. The agent sends requests to
`http://gateway:8080/<path>` without credentials. The proxy injects
the real key or token and forwards over TLS. For Telegram, the proxy
rewrites the URL to embed the bot token in the path. For Mattermost, it
injects the Bearer Authorization header. The agent process never sees
any API key, channel token, or auth secret.

**Layer 2 — Proxy-based auth verification.** The owner auth secret lives
exclusively in the proxy container. When a user sends `auth <token>`, the
agent's channel module sends an HTTP request to the proxy's `/auth/verify`
endpoint with the candidate token in an `X-Auth-Token` header. The proxy
compares it against the configured `OMEGACLAW_AUTH_SECRET` and returns
`{"match":true}` or `{"match":false}`. The agent never possesses the
secret — not in environment variables, files, Docker secrets, or memory.

**Layer 3 — Entrypoint environment scrubbing.** The entrypoint uses
`exec env -i` to replace itself with a clean environment containing only
allowlisted, non-secret variables. The agent runs as UID 65534 (set by
`USER` in the Dockerfile). This ensures `/proc/1/environ` contains
nothing sensitive.

**Layer 4 — Network isolation (restricted mode only).** The agent container
sits on a Docker internal network with no route to the internet. It can
only reach proxy services that bridge internal and external networks.

## Prerequisites

- Docker Engine 24+ with Compose V2
- An API key for your chosen LLM provider (Anthropic, OpenAI, ASI Cloud, or ASI:One)

## Quick Start (default — full network)

```bash
cd OmegaClaw-Core

# 1. Create your .env from the template
cp .env.example .env

# 2. Edit .env — set your API key, channel config, and owner secret
#    Generate a secret:  openssl rand -base64 24
nano .env

# 3. Build and start
docker compose up -d --build

# To stop:
docker compose down

# 4. Monitor logs
docker compose logs -f omegaclaw

# 5. Nuke volumes (agent memory) and full cleanup if needed:
docker compose down -v --remove-orphans --rmi all
```

The agent has full outbound internet access for web search, RAG, and
third-party integrations. API keys are still hidden in the proxy.

### Verify secret isolation

```bash
# 1. Agent runs as unprivileged user
docker compose exec omegaclaw id
# Expected: uid=65534(nobody) gid=65534(nogroup)

# 2. No secrets in agent's environment
docker compose exec omegaclaw env
# Expected: GATEWAY_URL, PATH, HOME — no OMEGACLAW_AUTH_SECRET, no tokens

# 3. Proxy auth endpoints work
docker compose exec omegaclaw python3 -c \
  "import urllib.request; print(urllib.request.urlopen('http://gateway:8080/auth/status').read().decode())"
# Expected: {"enabled":true}  (when OMEGACLAW_AUTH_SECRET is set)

docker compose exec omegaclaw python3 -c "
import urllib.request
r = urllib.request.Request('http://gateway:8080/auth/verify')
r.add_header('X-Auth-Token', 'wrong')
print(urllib.request.urlopen(r).read().decode())"
# Expected: {"match":false}

# 4. Bot tokens and auth secret in proxy only
docker compose exec gateway env | grep -E 'TG_BOT_TOKEN|MM_BOT_TOKEN|AUTH_SECRET'
docker compose exec omegaclaw env | grep -E 'TG_BOT_TOKEN|MM_BOT_TOKEN|AUTH_SECRET'
# First command shows tokens and secret; second shows nothing.
```

## Restricted Mode (no direct internet)

To run the agent with no direct internet access:

```bash
# In .env, set IRC_SERVER=irc-proxy so the agent routes through the proxy
docker compose -f docker-compose.restricted.yml up -d
```

In this mode the agent can only reach services on the Docker internal
network (gateway, irc-proxy). IRC works via irc-proxy once `IRC_SERVER`
is pointed at it in `.env`. Other channels and external services require
allowlisting (see below).

All three compose files share service definitions via `extends` from
`docker-compose.base.yml`, so configuration changes only need to be made
in one place.

## Network Allowlist (restricted mode)

In restricted mode the agent has no internet. To grant access to specific
external endpoints, add them as proxy pass-throughs.

### Option A — Add an nginx location (HTTP/HTTPS endpoints)

This works for any REST API: Telegram, Tavily, Agentverse, Mattermost, etc.

1. Add a `location` block in `proxy/nginx.conf.template`:

```nginx
location /telegram/ {
    proxy_pass https://api.telegram.org/;
    proxy_set_header Host api.telegram.org;
    proxy_ssl_server_name on;
    proxy_ssl_protocols TLSv1.2 TLSv1.3;
    proxy_http_version 1.1;
}
```

If the endpoint needs an API key, add the variable to
`docker-compose.restricted.yml` under `gateway.environment`:

```yaml
- TAVILY_API_KEY=${TAVILY_API_KEY:-}
```

Then use it in the nginx location:

```nginx
proxy_set_header Authorization "Bearer ${TAVILY_API_KEY}";
```

The proxy entrypoint auto-detects new `${VAR}` references in the template —
no changes to `entrypoint.sh` are needed.

2. Rebuild the proxy:

```bash
docker compose -f docker-compose.restricted.yml up -d --build gateway
```

### Option B — Add a socat service (raw TCP endpoints)

For non-HTTP protocols (IRC, raw WebSocket, etc.), add a socat relay
service in `docker-compose.restricted.yml`:

```yaml
services:
  mm-proxy:
    build:
      context: ./proxy
      dockerfile: Dockerfile.socat
    environment:
      - IRC_UPSTREAM_HOST=chat.singularitynet.io
      - IRC_UPSTREAM_PORT=443
    networks:
      - internal
      - external
    restart: unless-stopped
```

Add the new service to omegaclaw's `depends_on`, then point the agent at
the proxy hostname instead of the real server.

### Verifying the allowlist

```bash
# Confirm the proxy endpoint is reachable from the agent:
docker compose -f docker-compose.restricted.yml exec omegaclaw \
  wget -qO- http://gateway:8080/health

# Confirm direct internet is still blocked:
docker compose -f docker-compose.restricted.yml exec omegaclaw \
  wget -qO- http://example.com   # should fail
```

## Communication Channels

OmegaClaw supports multiple communication channels. Set `COMM_CHANNEL` in
`.env` to your choice and fill in the corresponding config.

| Channel      | `COMM_CHANNEL` | Required config                                        | Restricted mode                          |
|--------------|----------------|--------------------------------------------------------|------------------------------------------|
| IRC          | `irc`          | `IRC_CHANNEL`                                          | Works via irc-proxy (included)           |
| Telegram     | `telegram`     | `TG_BOT_TOKEN`                                         | Needs proxy for `api.telegram.org`       |
| Mattermost   | `mattermost`   | `MM_URL`, `MM_CHANNEL_ID`, `MM_BOT_TOKEN`              | Needs proxy for your Mattermost server   |

Future channels (Discord, Signal, Slack, etc.) follow the same pattern:
add the channel's config vars to `.env`, pass them through in the compose
`command` section, and — for restricted mode — add a proxy entry.

### Owner authentication

When `OMEGACLAW_AUTH_SECRET` is set to a non-empty value, the agent
requires the owner to send `auth <secret>` as their first message. The
first user who authenticates becomes the sole accepted sender — all
subsequent messages from other users are silently ignored. This works
identically across all channels (IRC, Telegram, Mattermost).

If `OMEGACLAW_AUTH_SECRET` is left empty or unset, owner authentication
is disabled and **any user on the channel can interact with the agent**.
This is suitable for private channels but should not be used on public
channels or shared servers.

## Feature Availability by Mode

| Feature              | Default | Restricted  |
|----------------------|---------|-------------|
| Chat (any channel)   | yes     | allowlist   |
| LLM inference        | yes     | yes         |
| API keys hidden      | yes     | yes         |
| DuckDuckGo search    | yes     | allowlist   |
| Tavily agent search  | yes     | allowlist   |
| Agentverse agents    | yes     | allowlist   |
| Web scraping / RAG   | yes     | allowlist   |

"allowlist" = works after adding a proxy entry (see above). IRC is
pre-configured via irc-proxy in the restricted compose file.

## Configuration Reference

All settings are in `.env`. See `.env.example` for the full list.

| Variable               | Required | Description                                              |
|------------------------|----------|----------------------------------------------------------|
| `ANTHROPIC_API_KEY`    | *        | Anthropic API key (set for `provider=Anthropic`)         |
| `ASI_API_KEY`          | *        | ASI Cloud API key (set for `provider=ASICloud`)          |
| `ASIONE_API_KEY`       | *        | ASI:One API key (set for `provider=ASIOne`)              |
| `OPENAI_API_KEY`       | *        | OpenAI API key (set for `provider=OpenAI`)               |
| `PROVIDER`             |          | LLM provider (default: `Anthropic`)                      |
| `EMBEDDING_PROVIDER`   |          | `Local` or `OpenAI` (default: `Local`)                   |
| `COMM_CHANNEL`         |          | `irc`, `telegram`, or `mattermost` (default: `irc`)      |
| `OMEGACLAW_AUTH_SECRET` |       | Owner auth secret (`openssl rand -base64 24`)            |
| `IRC_CHANNEL`          |          | IRC channel name                                         |
| `IRC_SERVER`           |          | Upstream IRC server (default: `irc.quakenet.org`)        |
| `IRC_PORT`             |          | Upstream IRC port (default: `6667`)                      |
| `TG_BOT_TOKEN`         |          | Telegram bot token                                       |
| `TG_POLL_TIMEOUT`      |          | Telegram polling timeout in seconds (default: `20`)      |
| `MM_URL`               |          | Mattermost server URL                                    |
| `MM_CHANNEL_ID`        |          | Mattermost channel ID                                    |
| `MM_BOT_TOKEN`         |          | Mattermost bot token                                     |

\* Set the key for your chosen provider. Others can be left blank.

## Adding a New API Key to the Proxy

To route a new external API through the proxy (hiding its key from the agent):

1. Add the key to `.env`
2. Add a `location` block in `proxy/nginx.conf.template` using `${YOUR_KEY}`
3. Pass the variable to `gateway` in the compose `environment` section
4. Rebuild: `docker compose up -d --build gateway`

The proxy entrypoint auto-detects `${VAR}` references in the nginx
template, so no changes to `proxy/entrypoint.sh` are needed.

## Read-Only Runtime

The container runs as UID 65534 (nobody) via the Dockerfile `USER`
directive. `security_opt: no-new-privileges` prevents privilege
escalation. Writable locations are limited to:

- `omegaclaw-memory` volume (mounted at the memory directory)
- `/tmp`, `/var/tmp` (tmpfs mounts, ephemeral)

All other paths (`/PeTTa`, the MeTTa runtime, agent source code) are
root-owned and read-only. This is intentional — it prevents the agent from
modifying its own code or runtime at the filesystem level.

## Known Limitations

1. **OpenAI provider**: The `useGPT` function in PeTTa's `lib_llm` reads
   `OPENAI_API_KEY` directly. The proxy cannot intercept this. In default
   mode this works naturally. In restricted mode, add `OPENAI_API_KEY` to
   the agent's environment in a compose override.

2. **Mattermost WebSocket**: Mattermost uses HTTPS and WSS. The proxy
   handles both HTTP API calls and WebSocket upgrades. The
   `proxy_read_timeout` is set to 300s for the Mattermost location to
   accommodate long-lived WebSocket connections.

3. **`git-import!` at startup**: `run.metta` calls `git-import!` for repos
   present in the Docker image. PeTTa skips cloning when the directory
   exists. If it attempts a `git fetch`, this fails harmlessly in restricted
   mode.

## Stopping and Cleaning Up

```bash
# Default mode
docker compose down
docker compose down -v          # also removes volumes (agent memory)

# Restricted mode
docker compose -f docker-compose.restricted.yml down
docker compose -f docker-compose.restricted.yml down -v
```

## Alternative: Interactive Script

The `scripts/omegaclaw` interactive setup script provides a guided
deployment path. When run from within the repository, it automatically
builds and starts the gateway alongside the agent container, providing
the same API key isolation as docker-compose. If the `proxy/` directory
is not found (e.g., the script is distributed standalone), it falls back
to passing the API key directly to the agent with a warning.

For persistent deployments, use `docker compose up -d --build`. The script
is best suited for quick evaluation and one-off runs — containers are
cleaned up automatically on exit.
