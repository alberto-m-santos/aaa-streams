# Self-Hosted Stremio Stack (Comet + Zilean + Prowlarr + StremThru)

Self-hosted Stremio addon stack backed by Real-Debrid.

## Stack

| Service       | Purpose                                          | Internal URL            |
|---------------|--------------------------------------------------|-------------------------|
| `comet`       | Stremio addon (SQLite, 1 worker)                 | `http://comet:8000`     |
| `zilean`      | DMM hash provider                                | `http://zilean:8181`    |
| `zilean-db`   | Postgres backing Zilean                          | `zilean-db:5432`        |
| `prowlarr`    | Background indexer scraper (cache warming)       | `http://prowlarr:9696`  |
| `stremthru`   | Debrid client (Real-Debrid)                      | `http://stremthru:8080` |
| `cloudflared` | Cloudflare Tunnel terminating at `comet:8000`    | -                       |

All containers share the `stremio-net` bridge network and reach each other by service name. Comet (`:8000`), Zilean (`:8181`), and Prowlarr (`:9696`) are published to the host for local/LAN debugging. StremThru and Cloudflared are internal-only.

## Request flow

```
Stremio -> Cloudflare Tunnel -> Comet -> Zilean (live, sub-second DMM query)
                                      |
                                      +-> Prowlarr (background cache-warm only)
                                      |
                                      v
                                 StremThru (localhost) -> Real-Debrid -> cached hashes
                                      |
                                      v
                                 Comet proxies bytes: RD CDN -> homelab -> viewer
```

Cold response ~1.5-2s, warm sub-second (Comet caches per title for 24h). Prowlarr runs in background mode only, warming the cache for titles Zilean doesn't have yet — it never blocks the live request.

## Prerequisites

- Linux host with Docker + Compose v2
- A Cloudflare account with a domain on Cloudflare DNS
- A Real-Debrid account

## 1. Configure secrets

```bash
cp .env.example .env
```

Generate strong random values:

```bash
openssl rand -base64 32   # POSTGRES_PASSWORD
openssl rand -base64 24   # COMET_ADMIN_PASSWORD
openssl rand -hex 24      # COMET_PUBLIC_API_TOKEN
```

Fill `.env`:
- `POSTGRES_PASSWORD` — random string, only used on the internal network
- `COMET_ADMIN_PASSWORD` — used for `/admin`, `/configure`, and the stream proxy
- `COMET_PUBLIC_API_TOKEN` — pinned token for the `/s/<token>/` Stremio URL prefix. Must be set explicitly; otherwise Comet auto-generates one inside the container and every container recreate breaks existing manifest URLs. Rotate this value to invalidate all existing manifest URLs in one shot.
- `CLOUDFLARE_TUNNEL_TOKEN` — see below
- `REALDEBRID_API_KEY` — from https://real-debrid.com/apitoken. Used as the server-side default for the stream proxy.
- `PROWLARR_API_KEY` — leave blank for now, fill after Prowlarr's first boot

### Create the Cloudflare Tunnel

1. Cloudflare Zero Trust dashboard -> **Networks -> Tunnels -> Create a tunnel -> Cloudflared**
2. Name it (e.g. `stremio`), copy the token into `CLOUDFLARE_TUNNEL_TOKEN`
3. **Public Hostnames** tab -> add:
   - Subdomain: `comet`
   - Domain: your domain
   - Service: `http://comet:8000`

No DNS A record or port forwarding needed — the tunnel is outbound-only from the server.

## 2. First boot

```bash
docker compose up -d zilean-db
docker compose logs zilean-db | tail   # wait for "ready to accept connections"

docker compose up -d zilean
docker compose logs zilean | tail      # ~30s: Entity Framework creates the Postgres schema and the API binds to :8181.
                                       # A separate DMM hash sync then runs in the background — see step 5.

docker compose up -d prowlarr cloudflared
```

## 3. Configure Prowlarr

1. Open `http://<server-ip>:9696`
2. Set admin auth on the first-run screen (Forms + Login Page)
3. **Settings -> General -> Security** -> copy the **API Key**
4. Paste into `.env` as `PROWLARR_API_KEY`
5. **Indexers -> Add Indexer**. As of Apr 2026, these work without FlareSolverr:
   - **Knaben** (meta-aggregator covering ~30 sites, essential)
   - **The Pirate Bay**
   - **YTS**

   Cloudflare-blocked (need FlareSolverr container to work): 1337x, EZTV, TheRARBG.
6. After indexers are added, run **System -> Tasks -> Indexer Definition Update** if you can't find specific indexers in the list

Then boot Comet:

```bash
docker compose up -d comet
```

## 4. Verify the startup log

```bash
docker compose logs comet | grep -iE "scraper|password|proxy|torrent"
```

Check that Zilean/Prowlarr scrapers, both passwords, proxy settings, and `Disable Torrent Streams: True` are all set.

## 5. Seed the Zilean DMM hash database

Zilean boots in two phases: schema migrations (~30s, API comes online) then a background DMM hash sync that takes several hours on first boot. Comet works immediately via Prowlarr fallback while Zilean is still seeding. Monitor with `docker compose logs zilean --tail 20`.

## 6. Lock down `/configure` and `/admin` with Cloudflare Access

Zero Trust -> **Access -> Applications -> Add an application -> Self-hosted**:

**App 1:**
- Name: `Comet Configure`
- Session duration: 24 hours
- Public hostname: your tunnel domain, path `configure`
- Policy: Allow -> Include -> Emails -> your email (plus any friends you want to let self-configure)

**App 2:** repeat with path `admin`, name `Comet Admin`.

Do NOT protect the root path or `/s/*` — Stremio needs those reachable without interactive login.

## 7. Install in Stremio

1. Open `https://comet.<your-domain>/configure` (you'll hit Cloudflare Access first, then the Comet Configure Page Password)
2. Fill the form:
   - **Resolutions**: select 2160p / 1440p / 1080p / 720p (exclude 480p and below)
   - **Debrid Stream Proxy Password**: paste your `COMET_ADMIN_PASSWORD`
   - **Debrid Services**: leave empty to use the server-side default RD key
   - ✅ **Deduplicate Streams**
   - ☐ **Scrape Debrid Account Torrents** (disable — adds latency for near-zero value)
3. **Advanced Settings**:
   - ✅ **Show Cached Only**
   - ✅ **Remove Trash**
4. Click **Install** (opens `stremio://`) or **Copy Link** and paste manually into Stremio -> Addons -> Add addon

Save the manifest URL in a password manager. It contains the `COMET_PUBLIC_API_TOKEN` that authorizes Stremio against your instance.

## Filter rules (set via env)

- **Excluded resolutions**: 480p, 360p, 240p, 144p, Unknown
- **Excluded title regex**: `(?i)\b(cam|hdcam|ts|telesync|hdts|hdtc|tc)\b`
- **Prowlarr timeout**: 2000ms hard cap (UI never hangs on slow trackers)
- **Torrent streams**: disabled — all playback goes through RD, zero P2P path

## Exposed ports

| Port | Service  | Notes                                                    |
|------|----------|----------------------------------------------------------|
| 8000 | Comet    | LAN debugging; tunnel is still the external path         |
| 8181 | Zilean   | API + health, useful for debugging                       |
| 9696 | Prowlarr | Web UI for indexer management                            |
| -    | StremThru| Internal only, reached via bridge network                |

Firewall the host so these are only reachable from trusted LAN or via SSH tunnel.

## Common operations

```bash
# Status
docker compose ps

# Logs
docker compose logs -f comet
docker compose logs zilean --tail 50

# Restart Comet after editing filters / env
docker compose up -d comet

# Force DMM re-scrape
curl -X POST http://localhost:8181/api/v1/dmm/on-demand-scrape

# Postgres shell
docker compose exec zilean-db psql -U zilean -d zilean

# Wipe Comet SQLite if it ever gets into a weird state (anime cache regenerates on boot)
docker compose stop comet
rm -f data/comet/comet.db data/comet/comet.db-shm data/comet/comet.db-wal
docker compose up -d comet
```
