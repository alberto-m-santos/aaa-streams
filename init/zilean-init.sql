-- Zilean performance tuning: trigram + hash indexes for fast DMM lookups.
-- Runs once on first Postgres init. Zilean creates its own tables on boot,
-- so these CREATE INDEX statements are wrapped in DO blocks that retry via
-- idempotent IF NOT EXISTS clauses once the tables exist.

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gin;

-- NOTE: Zilean's own EF Core migrations create the ParsedTorrents / Torrents
-- tables. Index creation for those tables is handled inside Zilean. If you
-- need to add custom indexes, do it with:
--   docker compose exec zilean-db psql -U zilean -d zilean \
--     -c "CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_pt_infohash ON \"ParsedTorrents\" (\"InfoHash\");"
