--
-- These are the migrations for the PostgreSQL Minion backend. They are only used for upgrades to the latest version.
-- Downgrades may be used to clean up the database, but they do not have to work with old versions of Minion.
--
-- 18 up
CREATE TYPE minion_state AS ENUM ('inactive', 'active', 'failed', 'finished');
CREATE TABLE IF NOT EXISTS minion_jobs (
  id       BIGSERIAL NOT NULL PRIMARY KEY,
  args     JSONB NOT NULL CHECK(JSONB_TYPEOF(args) = 'array'),
  attempts INT NOT NULL DEFAULT 1,
  created  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
  delayed  TIMESTAMP WITH TIME ZONE NOT NULL,
  finished TIMESTAMP WITH TIME ZONE,
  notes    JSONB CHECK(JSONB_TYPEOF(notes) = 'object') NOT NULL DEFAULT '{}',
  parents  BIGINT[] NOT NULL DEFAULT '{}',
  priority INT NOT NULL,
  queue    TEXT NOT NULL DEFAULT 'default',
  result   JSONB,
  retried  TIMESTAMP WITH TIME ZONE,
  retries  INT NOT NULL DEFAULT 0,
  started  TIMESTAMP WITH TIME ZONE,
  state    minion_state NOT NULL DEFAULT 'inactive'::MINION_STATE,
  task     TEXT NOT NULL,
  worker   BIGINT
);
CREATE INDEX ON minion_jobs (state, priority DESC, id);
CREATE INDEX ON minion_jobs USING GIN (parents);
CREATE TABLE IF NOT EXISTS minion_workers (
  id       BIGSERIAL NOT NULL PRIMARY KEY,
  host     TEXT NOT NULL,
  inbox    JSONB CHECK(JSONB_TYPEOF(inbox) = 'array') NOT NULL DEFAULT '[]',
  notified TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
  pid      INT NOT NULL,
  started  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
  status   JSONB CHECK(JSONB_TYPEOF(status) = 'object') NOT NULL DEFAULT '{}'
);
CREATE UNLOGGED TABLE IF NOT EXISTS minion_locks (
  id      BIGSERIAL NOT NULL PRIMARY KEY,
  name    TEXT NOT NULL,
  expires TIMESTAMP WITH TIME ZONE NOT NULL
);
CREATE INDEX ON minion_locks (name, expires);

CREATE OR REPLACE FUNCTION minion_jobs_notify_workers() RETURNS trigger AS $$
  BEGIN
    IF new.delayed <= NOW() THEN
      NOTIFY "minion.job";
    END IF;
    RETURN NULL;
  END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER minion_jobs_notify_workers_trigger
  AFTER INSERT OR UPDATE OF retries ON minion_jobs
  FOR EACH ROW EXECUTE PROCEDURE minion_jobs_notify_workers();

CREATE OR REPLACE FUNCTION minion_lock(TEXT, INT, INT) RETURNS BOOL AS $$
DECLARE
  new_expires TIMESTAMP WITH TIME ZONE = NOW() + (INTERVAL '1 second' * $2);
BEGIN
  lock TABLE minion_locks IN exclusive mode;
  DELETE FROM minion_locks WHERE expires < NOW();
  IF (SELECT COUNT(*) >= $3 FROM minion_locks WHERE NAME = $1) THEN
    RETURN false;
  END IF;
  IF new_expires > NOW() THEN
    INSERT INTO minion_locks (name, expires) VALUES ($1, new_expires);
  END IF;
  RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- 18 down
DROP TABLE IF EXISTS minion_jobs;
DROP TABLE if EXISTS minion_workers;
DROP TABLE IF EXISTS minion_locks;
DROP TYPE IF EXISTS minion_state;
DROP TRIGGER IF EXISTS minion_jobs_notify_workers_trigger ON minion_jobs;
DROP FUNCTION IF EXISTS minion_jobs_notify_workers();
DROP FUNCTION IF EXISTS minion_lock(TEXT, INT, INT);

-- 19 up
CREATE INDEX ON minion_jobs USING GIN (notes);

-- 20 up
ALTER TABLE minion_workers SET UNLOGGED;

-- 22 up
ALTER TABLE minion_jobs DROP COLUMN IF EXISTS SEQUENCE;
ALTER TABLE minion_jobs DROP COLUMN IF EXISTS NEXT;
ALTER TABLE minion_jobs ADD COLUMN EXPIRES TIMESTAMP WITH TIME ZONE;
CREATE INDEX ON minion_jobs (expires);

-- 23 up
ALTER TABLE minion_jobs ADD COLUMN lax BOOL NOT NULL DEFAULT FALSE;

-- 24 up
CREATE INDEX ON minion_jobs (finished, state);
