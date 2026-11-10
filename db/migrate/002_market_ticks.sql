-- © 2026 aiaiaiai · aiaiaiai.org
-- SPDX-License-Identifier: MIT

-- One row per live stream connection. A quote series is only as good as its coverage, so
-- every connection records when it started and ended: the time between two sessions is a
-- gap in which no tick was observed, and it must stay visible to whoever reads the ticks.
CREATE TABLE trading_lab.market_stream_sessions (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source text NOT NULL,
  instruments text[] NOT NULL,
  connected_at timestamptz NOT NULL,
  ended_at timestamptz,
  end_reason text,
  ticks bigint NOT NULL DEFAULT 0,
  CHECK (ended_at IS NULL OR ended_at >= connected_at)
);

CREATE INDEX market_stream_sessions_source ON trading_lab.market_stream_sessions (source, id DESC);

-- Ticks in collection order (id). received_at is the collector's own clock at receipt and
-- is the only causal timestamp: exchange_at is what the exchange claims and may be earlier,
-- so a simulation that keyed on it could see a quote before the lab had it.
CREATE TABLE trading_lab.market_ticks (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  session_id bigint NOT NULL REFERENCES trading_lab.market_stream_sessions (id),
  instrument text NOT NULL,
  received_at timestamptz NOT NULL,
  exchange_at timestamptz NOT NULL,
  last numeric NOT NULL CHECK (last > 0),
  bid numeric CHECK (bid > 0),
  ask numeric CHECK (ask > 0),
  bid_size numeric,
  ask_size numeric
);

CREATE INDEX market_ticks_instrument_received ON trading_lab.market_ticks (instrument, received_at);

CREATE TRIGGER market_ticks_append_only BEFORE UPDATE OR DELETE ON trading_lab.market_ticks
  FOR EACH ROW EXECUTE FUNCTION trading_lab.reject_change();
