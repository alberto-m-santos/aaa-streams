# Self-Hosted Stremio Stack (Comet + Zilean + Prowlarr)

High-performance Stremio addon stack optimized for low latency and Day-1 release availability.

## Stack

| Service       | Purpose                                         | Internal URL              |
|---------------|-------------------------------------------------|---------------------------|
| `comet`       | Stremio addon (SQLite)                          | `http://comet:8000`       |
| `zilean`      | Primary DMM hash provider                       | `http://zilean:8181`      |
| `zilean-db`   | Tuned Postgres 16 backing Zilean                | `zilean-db:5432`          |
| `prowlarr`    | Real-time scraper backup (2s timeout in Comet)  | `http://prowlarr:9696`    |
| `cloudflared` | Cloudflare Tunnel -> `comet:8000` with SSL      | -                         |

All containers share the `stremio-net` bridge network and reach each other by service name.

## Prerequisites

- Docker + Docker Compose v2
- A Cloudflare account with a domain on Cloudflare DNS
- Real-Debrid account (or AllDebrid / Premiumize / TorBox)

## 1. Configure secrets

```bash
cp .env.example .env
# Edit .env and fill POSTGRES_PASSWORD, COMET_ADMIN_PASSWORD, CLOUDFLARE_TUNNEL_TOKEN
# Leave PROWLARR_API_KEY blank for now.
```

### Create the Cloudflare Tunnel

1. Cloudflare Zero Trust dashboard -> **Networks** -> **Tunnels** -> **Create a tunnel** -> **Cloudflared**
2. Name it (e.g. `stremio`), copy the token into `CLOUDFLARE_TUNNEL_TOKEN` in `.env`
3. Under **Public Hostnames**, add:
   - Subdomain: `comet`
   - Domain: `example.com` (replace with yours)
   - Service: `http://comet:8000`

## 2. First boot

```bash
docker compose up -d zilean-db
docker compose up -d zilean          # wait ~30s for EF migrations
docker compose up -d prowlarr cloudflared
```

## 3. Configure Prowlarr

1. Open `http://localhost:9696`
2. Set an admin password on the first-run screen
3. **Settings -> General -> Security**: copy the **API Key**
4. Paste it into `.env` as `PROWLARR_API_KEY`
5. **Indexers -> Add Indexer**: add public indexers (1337x, TheRARBG, TPB, EZTV, YTS, TorrentGalaxy, etc.)
6. Start Comet now that the API key exists:

```bash
docker compose up -d comet
```

## 4. Seed the Zilean DMM hash database

Zilean auto-runs its DMM import job on boot, but the first full sync can take
20-40 minutes. To force/monitor it:

```bash
# Trigger a fresh DMM sync
curl -X POST http://localhost:8181/api/v1/dmm/on-demand-scrape

# Watch progress
docker compose logs -f zilean
```

Until the import finishes, Comet falls back to Prowlarr scraping (hence the 2s
timeout: the UI never stalls).

## 5. Install in Stremio

1. Open `https://comet.example.com/configure` (the Cloudflare hostname you created)
2. Fill the form:
   - **Debrid service**: Real-Debrid (or your choice)
   - **Debrid API key**: paste your RD key
   - Confirm resolution exclusions (`480p`, `360p`, `240p`, `144p`, `Unknown`) and the
     title-exclude regex are pre-populated from env defaults
3. Click **Install** -> it opens `stremio://` and installs the addon, or copy the
   **Manifest URL** and paste it into Stremio: **Addons -> Add addon -> paste URL**

## Filter rules (already set via env)

- **Excluded resolutions**: 480p, 360p, 240p, 144p, Unknown (everything 720p+ passes)
- **Excluded title regex**: `(?i)\b(cam|hdcam|ts|telesync|hdts|hdtc|tc)\b`
- **Prowlarr timeout**: 2000ms (hard cap on slow tracker queries)

## Exposed ports

| Port | Service   | Notes                                    |
|------|-----------|------------------------------------------|
| 8181 | Zilean    | API + health, handy for debugging        |
| 9696 | Prowlarr  | Web UI                                   |
| -    | Comet     | Tunnel-only, no host port published      |

Lock these down with a firewall if the host is internet-facing — they have no
auth by default.

## Common operations

```bash
# Status
docker compose ps

# Tail everything
docker compose logs -f

# Restart Comet after editing filters / env
docker compose up -d comet

# Re-import DMM hashes manually
curl -X POST http://localhost:8181/api/v1/dmm/on-demand-scrape

# Postgres shell (for custom indexes / tuning)
docker compose exec zilean-db psql -U zilean -d zilean
```

## Troubleshooting

- **No streams returned**: check `docker compose logs comet` — if Zilean returns 0
  hits and Prowlarr times out, the DMM import probably hasn't finished yet.
- **Cloudflare 502**: `cloudflared` starts before `comet` is ready on first boot.
  `docker compose restart cloudflared` after Comet is healthy.
- **Prowlarr API key changed**: update `.env` and `docker compose up -d comet` to
  reload the env.
