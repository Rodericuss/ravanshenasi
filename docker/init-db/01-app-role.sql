-- Ravanshenasi application role.
--
-- The app must not connect as a superuser or with BYPASSRLS, otherwise the Row
-- Level Security (RLS) that isolates tenants is silently bypassed. This role is
-- regular (without SUPERUSER/BYPASSRLS) and owns the data, so `FORCE RLS` works.
--
-- Runs automatically on the container's FIRST boot (empty volume), via
-- /docker-entrypoint-initdb.d. Idempotent.
--
-- If the image in use does not run /docker-entrypoint-initdb.d, run manually:
--   docker compose exec -T db psql -U postgres -f /docker-entrypoint-initdb.d/01-app-role.sql

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ravanshenasi_app') THEN
    CREATE ROLE ravanshenasi_app WITH LOGIN PASSWORD 'ravanshenasi_app' CREATEDB;
  END IF;
END
$$;

-- POSTGRES_DB (ravanshenasi_dev) is created by the entrypoint as `postgres`.
-- Transfers ownership to the app role: tables (created by migrations running as
-- the app) remain under effective FORCE RLS.
ALTER DATABASE ravanshenasi_dev OWNER TO ravanshenasi_app;
