-- © 2026 aiaiaiai · aiaiaiai.org
-- SPDX-License-Identifier: MIT

-- Layer 1, raw source: one row per channel post and one immutable row per observed state
-- of it. A channel that edits or deletes a call after the market moved keeps every earlier
-- version here, stamped with the time the lab saw it.
CREATE TABLE trading_lab.telegram_messages (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  channel text NOT NULL CHECK (channel ~ '^[a-z][a-z0-9_]{3,31}$'),
  message_id bigint NOT NULL CHECK (message_id > 0),
  published_at timestamptz NOT NULL,
  first_seen_at timestamptz NOT NULL,
  -- First seen while reading older pages at start-up rather than while polling: kept as
  -- evidence, never rated, whatever its timestamps say.
  backfilled boolean NOT NULL,
  UNIQUE (channel, message_id)
);

CREATE TABLE trading_lab.telegram_message_revisions (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  message_ref bigint NOT NULL REFERENCES trading_lab.telegram_messages (id),
  revision integer NOT NULL CHECK (revision > 0),
  kind text NOT NULL CHECK (kind IN ('original', 'edit', 'deleted')),
  -- The lab's clock when this state was first seen: the earliest moment anyone following
  -- the lab could have acted on it.
  observed_at timestamptz NOT NULL,
  marked_edited boolean NOT NULL,
  text text NOT NULL,
  text_digest text NOT NULL CHECK (text_digest ~ '^[0-9a-f]{64}$'),
  UNIQUE (message_ref, revision)
);

-- Layer 2, signal candidate: what a deterministic parser read in one revision.
CREATE TABLE trading_lab.telegram_signals (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  revision_id bigint NOT NULL UNIQUE REFERENCES trading_lab.telegram_message_revisions (id),
  instrument text NOT NULL,
  side text NOT NULL CHECK (side IN ('long', 'short')),
  entry_low numeric CHECK (entry_low > 0),
  entry_high numeric CHECK (entry_high >= entry_low),
  stop numeric CHECK (stop > 0),
  targets numeric[] NOT NULL,
  parser_version integer NOT NULL
);

-- Layer 3, outcome: how a signal did against prices observed after the lab saw it. One
-- final row per signal, written once.
CREATE TABLE trading_lab.telegram_signal_outcomes (
  signal_id bigint PRIMARY KEY REFERENCES trading_lab.telegram_signals (id),
  evaluated_at timestamptz NOT NULL,
  outcome text NOT NULL CHECK (outcome IN ('target', 'stop', 'expired', 'missed', 'no_quote')),
  horizon_hours integer NOT NULL CHECK (horizon_hours > 0),
  entry_at timestamptz,
  entry_price numeric,
  exit_at timestamptz,
  exit_price numeric,
  return numeric
);

CREATE TRIGGER telegram_messages_append_only BEFORE UPDATE OR DELETE ON trading_lab.telegram_messages
  FOR EACH ROW EXECUTE FUNCTION trading_lab.reject_change();
CREATE TRIGGER telegram_message_revisions_append_only BEFORE UPDATE OR DELETE ON trading_lab.telegram_message_revisions
  FOR EACH ROW EXECUTE FUNCTION trading_lab.reject_change();
CREATE TRIGGER telegram_signals_append_only BEFORE UPDATE OR DELETE ON trading_lab.telegram_signals
  FOR EACH ROW EXECUTE FUNCTION trading_lab.reject_change();
CREATE TRIGGER telegram_signal_outcomes_append_only BEFORE UPDATE OR DELETE ON trading_lab.telegram_signal_outcomes
  FOR EACH ROW EXECUTE FUNCTION trading_lab.reject_change();
