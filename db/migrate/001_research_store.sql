-- © 2026 aiaiaiai · aiaiaiai.org
-- SPDX-License-Identifier: MIT

-- Research history of the paper lab. Everything lives in its own schema, so the lab can
-- share a PostgreSQL database with another product without touching its tables.
CREATE TABLE trading_lab.experiments (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name text NOT NULL UNIQUE CHECK (name ~ '^[a-z0-9][a-z0-9._-]{0,62}$'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE trading_lab.simulation_runs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('paper_replay', 'copy_replay')),
  experiment_id bigint REFERENCES trading_lab.experiments (id),
  -- What was simulated: the lead trader's unique code for a copy replay.
  subject text,
  options jsonb NOT NULL,
  -- SHA-256 of the exact input, so two runs over the same data can be told from two
  -- runs over different data that happen to share options.
  input_digest text NOT NULL CHECK (input_digest ~ '^[0-9a-f]{64}$'),
  equity numeric NOT NULL,
  net_pnl numeric NOT NULL,
  max_drawdown numeric,
  -- The paper portfolio the run ended with: cash, equity and open positions.
  portfolio jsonb NOT NULL,
  result jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX simulation_runs_kind ON trading_lab.simulation_runs (kind, id DESC);
CREATE INDEX simulation_runs_subject ON trading_lab.simulation_runs (subject, id DESC) WHERE subject IS NOT NULL;
CREATE INDEX simulation_runs_experiment ON trading_lab.simulation_runs (experiment_id, id DESC) WHERE experiment_id IS NOT NULL;

-- A recorded result that can be edited afterwards is not evidence. Rows are append-only.
CREATE FUNCTION trading_lab.reject_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END;
$$;

CREATE TRIGGER simulation_runs_append_only BEFORE UPDATE OR DELETE ON trading_lab.simulation_runs
  FOR EACH ROW EXECUTE FUNCTION trading_lab.reject_change();
