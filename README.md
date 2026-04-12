# Self-Hosted Stremio Stack (Comet + Zilean + Prowlarr)

High-performance Stremio addon stack optimized for low latency, Day-1 release availability, and private multi-user sharing through a single Real-Debrid account.

## Stack

| Service       | Purpose                                         | Internal URL              |
|---------------|-------------------------------------------------|---------------------------|
| `comet`       | Stremio addon (SQLite, 1 worker)                | `http://comet:8000`       |
| `zilean`      | Primary DMM hash provider                       | `http://zilean:8181`      |
| `zilean-db`   | Tuned Postgres 16 backing Zilean                | `zilean-db:5432`          |
| `prowlarr`    | Real-time scraper fallback (2s hard timeout)    | `http://prowlarr:9696`    |
| `cloudflared` | Cloudflare Tunnel terminating at `comet:8000`   | -                         |

All containers share the `stremio-net` bridge network and reach each other by service name. Only Zilean (`:8181`) and Prowlarr (`:9696`) are published to the host for local debugging; Comet is tunnel-only.

## Request flow

```
Stremio -> Cloudflare Tunnel -> Comet -> { Zilean (primary) , Prowlarr (fallback, 2s cap) }
                                      |
                                      v
                                 StremThru -> Real-Debrid -> CDN URL
```

Cold-path response is typically 2-4s (first time a title is searched). Warm-path is sub-second (Comet caches Zilean/Prowlarr results for 24h per title).

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
```

Fill `.env`:
- `POSTGRES_PASSWORD` — random string, only used on the internal network
- `COMET_ADMIN_PASSWORD` — used for `/admin`, `/configure`, and the stream proxy
- `CLOUDFLARE_TUNNEL_TOKEN` — see below
- `REALDEBRID_API_KEY` — from https://real-debrid.com/apitoken. Used as the server-side default for the stream proxy, so friends never need their own RD account
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

Expected:
```
Zilean Scraper: both - http://zilean:8181
Prowlarr Scraper: both - http://prowlarr:9696 - Indexers: knaben, thepiratebay, yts
Admin Dashboard Password: <first 6 chars>*******
Configure Page Password: <first 6 chars>*******
Debrid Stream Proxy: True - Password: <first 6 chars>******* - Default Debrid Service: realdebrid - Default Debrid API Key: <first 6 chars>*******
Disable Torrent Streams: True
```

## 5. Seed the Zilean DMM hash database

Zilean has two distinct startup phases. Do not confuse them:

1. **Schema migrations (~30 seconds)** — Entity Framework creates the Postgres tables and indexes. The API binds to `:8181` and starts accepting requests as soon as this finishes. This is what's done when you see `Migrations Applied` in the logs.

2. **DMM hash sync (several hours on first boot)** — a background job that downloads and imports ~1.3M IMDB basics entries plus the full DMM hash dump into the Postgres tables. This runs *after* migrations finish and keeps going long after the API is live. During this phase the DB is progressively filling up; queries return whatever is already imported. First-boot full sync is typically **2-6 hours** depending on disk, network, and DMM dump size. After that, incremental syncs run periodically to keep the DB fresh with new releases (no cron needed).

Monitor progress:

```bash
docker compose logs zilean --tail 20
curl http://localhost:8181/torrents/count   # watch this climb
```

Comet will work immediately using Prowlarr fallback while Zilean is still seeding. Once Zilean is complete you'll get the full DMM catalog and sub-second warm responses.

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
   - **Debrid Services**: **leave empty** if using the server-side default RD key (recommended). If you want to use a different RD account for this specific manifest, add it here.
   - ✅ **Deduplicate Streams**
   - ☐ **Scrape Debrid Account Torrents** (disable — broken against public StremThru and adds latency)
3. **Advanced Settings**:
   - ✅ **Show Cached Only**
   - ✅ **Remove Trash**
4. Click **Install** (opens `stremio://`) or **Copy Link** and paste manually into Stremio -> Addons -> Add addon

Save the manifest URL in a password manager. It contains the auto-generated token that authorizes Stremio against your instance.

## Sharing with friends (single RD account)

The stack is designed to let trusted friends use your Real-Debrid account through the stream proxy without knowing the API key.

**Setup per friend:**

1. Add their email to the Cloudflare Access `Comet Configure` policy
2. Send them `https://comet.<your-domain>/configure` and the Configure Page Password (out-of-band, e.g. Signal)
3. Instruct them:
   - Log in via Cloudflare email OTP (one-time)
   - Enter the Configure Page password
   - Set resolutions and filters
   - **Leave Debrid Services empty** — critical, this is what makes the server-side default RD key kick in
   - Set the Debrid Stream Proxy Password to the shared value
   - Click Install, copy the manifest URL, paste into Stremio
4. Once they've saved the URL in Stremio, **they never need Cloudflare Access again** — stream endpoints are token-gated, not Access-gated. You can remove them from the Access policy after setup if you want.

**Revoking a friend:**
- Remove their email from Cloudflare Access (stops them generating new manifest URLs)
- To also kill their existing URL: rotate `COMET_ADMIN_PASSWORD` in `.env` and `docker compose up -d comet`. All existing manifest URLs (yours and friends') will stop playing streams until you regenerate them with the new password.

**Capacity limits:**
- RD enforces ~16 concurrent download slots per account — safe for ~5-10 simultaneous viewers
- RD 1TB/day traffic cap — ~27 hours of 4K REMUX per day
- Gigabit symmetric uplink handles ~9 concurrent 4K REMUX streams before saturation
- Comet's SQLite + 1-worker setup is fine for this scale; migrate to Postgres if scaling beyond ~10 concurrent users

**Do NOT share with strangers.** RD's fair-use ToS tolerates small friend/family sharing but bans commercial or public sharing. Keep the circle small and trusted.

## Filter rules (set via env)

- **Excluded resolutions**: 480p, 360p, 240p, 144p, Unknown
- **Excluded title regex**: `(?i)\b(cam|hdcam|ts|telesync|hdts|hdtc|tc)\b`
- **Prowlarr timeout**: 2000ms hard cap (UI never hangs on slow trackers)
- **Torrent streams**: disabled — all playback goes through RD, zero P2P path

## Exposed ports

| Port | Service  | Notes                                           |
|------|----------|-------------------------------------------------|
| 8181 | Zilean   | API + health, useful for debugging              |
| 9696 | Prowlarr | Web UI for indexer management                   |
| -    | Comet    | Tunnel-only, never published to the host        |

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

# Zilean hash count (monitors DMM import progress)
curl http://localhost:8181/torrents/count

# Postgres shell
docker compose exec zilean-db psql -U zilean -d zilean

# Wipe Comet SQLite if it ever gets into a weird state (anime cache regenerates on boot)
docker compose stop comet
rm -f data/comet/comet.db data/comet/comet.db-shm data/comet/comet.db-wal
docker compose up -d comet
```

## Troubleshooting

**Stremio shows no streams for a title that should exist**
Usually means the stream request took longer than Stremio's ~8s timeout. Re-open the title and try again — Comet's cache makes the second request sub-second. If cold requests are consistently slow, check `docker compose logs comet` for `warm sync timed out` — the `DEBRID_ACCOUNT_SCRAPE_INITIAL_WARM_TIMEOUT=1.0` env should keep this in check.

**`database is locked` at boot**
`FASTAPI_WORKERS` must be `1` when using SQLite. Multi-worker causes races on the WAL mode setting. If you need concurrency, migrate to Postgres.

**Manifest URL returns 404 at `/manifest.json`**
Because `CONFIGURE_PAGE_PASSWORD` is set, Comet serves all Stremio API endpoints under `/s/<token>/...`. You never need to know the token manually — `/configure`'s Install/Copy Link buttons generate the full URL for you.

**Prowlarr can't add 1337x / EZTV / TheRARBG**
Those sites are behind Cloudflare challenges that Prowlarr's HTTP client can't solve. Either skip them (Knaben aggregates most of their content) or add a FlareSolverr container and tag those indexers to route through it.

**StremThru `list_magnets` exception in logs**
The public StremThru instance has a known bug parsing RD's magnet list. It only affects the account-scrape feature, which you should have disabled in `/configure` anyway. Safe to ignore.

**Cloudflare 502 right after first boot**
`cloudflared` starts before Comet is ready. `docker compose restart cloudflared` once Comet is up.
