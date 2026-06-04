-- Role de aplicação do Ravanshenasi.
--
-- A app NÃO pode conectar como superuser nem com BYPASSRLS, senão o Row Level
-- Security (RLS) que isola os tenants é silenciosamente ignorado. Esta role é
-- comum (sem SUPERUSER/BYPASSRLS) e dona dos dados, para que `FORCE RLS` valha.
--
-- Roda automaticamente no PRIMEIRO boot do container (volume vazio), via
-- /docker-entrypoint-initdb.d. Idempotente.
--
-- Se a imagem usada não executar /docker-entrypoint-initdb.d, rode manualmente:
--   docker compose exec -T db psql -U postgres -f /docker-entrypoint-initdb.d/01-app-role.sql

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ravanshenasi_app') THEN
    CREATE ROLE ravanshenasi_app WITH LOGIN PASSWORD 'ravanshenasi_app' CREATEDB;
  END IF;
END
$$;

-- O POSTGRES_DB (ravanshenasi_dev) é criado pelo entrypoint como `postgres`.
-- Passa a ownership para a role da app: as tabelas (criadas via migrations
-- rodando como a app) ficam sob FORCE RLS efetivo.
ALTER DATABASE ravanshenasi_dev OWNER TO ravanshenasi_app;
