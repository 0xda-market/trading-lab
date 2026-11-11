# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "digest"
require "json"
require "time"
require_relative "research_store"
require_relative "signal_parser"
require_relative "telegram_preview"

module ZeroXDA
  module TradingLab
    # Channel posts, every observed revision of them, the signals read from those revisions
    # and the outcome of each signal.
    class TelegramSignalStore
      S = ResearchStore::SCHEMA
      OUTCOMES = %w[target stop expired missed no_quote].freeze
      # A call first seen later than this after it was published is not rated.
      MAX_LAG_SECONDS = 300
      # The call a message is judged by: the first of its revisions that carried a signal.
      # Whatever the channel changed afterwards cannot improve its record.
      CALLS = "SELECT DISTINCT ON (r.message_ref) r.message_ref, r.revision, r.kind, r.observed_at, s.id AS signal_id, " \
              "m.channel, m.message_id, m.published_at, m.backfilled FROM #{S}.telegram_signals s " \
              "JOIN #{S}.telegram_message_revisions r ON r.id = s.revision_id " \
              "JOIN #{S}.telegram_messages m ON m.id = r.message_ref ORDER BY r.message_ref, r.revision"
      # An original first seen long after it was published (a collector that was down), or
      # found by a backfill at all, cannot be rated: nobody knows what it said when it was new.
      LATE = "(c.backfilled OR (c.kind = 'original' AND c.observed_at - c.published_at > make_interval(secs => $1)))"

      def initialize(store, parser: SignalParser)
        @store = store
        @parser = parser
      end

      # Stores what one preview page showed at `observed_at`: new posts, changed text as an
      # edit, and a known post that vanished from between its neighbours as a deletion.
      # Posts first seen through a `backfill` are marked so that they are never rated.
      def record_page(channel, messages, observed_at, backfill: false)
        counts = { "new" => 0, "edited" => 0, "deleted" => 0, "signals" => 0 }
        return counts if messages.empty?
        ids = messages.map { |message| message.fetch("message_id") }
        at = observed_at.iso8601(6)
        @store.with do |db|
          db.transaction do
            known = db.exec_params(
              "SELECT m.id, m.message_id, r.revision, r.kind, r.text_digest FROM #{S}.telegram_messages m JOIN LATERAL " \
              "(SELECT revision, kind, text_digest FROM #{S}.telegram_message_revisions WHERE message_ref = m.id " \
              "ORDER BY revision DESC LIMIT 1) r ON true WHERE m.channel = $1 AND m.message_id BETWEEN $2 AND $3 FOR UPDATE OF m",
              [channel, ids.min, ids.max]
            ).to_h { |row| [Integer(row["message_id"], 10), row] }
            messages.each do |message|
              digest = Digest::SHA256.hexdigest(message.fetch("text"))
              seen = known.delete(message["message_id"])
              if seen.nil?
                ref = db.exec_params("INSERT INTO #{S}.telegram_messages (channel, message_id, published_at, first_seen_at, backfilled) " \
                                     "VALUES ($1, $2, $3, $4, $5) RETURNING id",
                                     [channel, message["message_id"], message.fetch("published_at"), at, backfill ? "t" : "f"]).first["id"]
                counts["signals"] += revise(db, ref, 1, "original", at, message, digest)
                counts["new"] += 1
              elsif seen["kind"] == "deleted" || seen["text_digest"] != digest
                counts["signals"] += revise(db, seen["id"], Integer(seen["revision"], 10) + 1, "edit", at, message, digest)
                counts["edited"] += 1
              end
            end
            known.each_value do |seen|
              next if seen["kind"] == "deleted"
              gone = { "text" => "", "edited" => false }
              revise(db, seen["id"], Integer(seen["revision"], 10) + 1, "deleted", at, gone, Digest::SHA256.hexdigest(""))
              counts["deleted"] += 1
            end
          end
        end
        counts
      end

      # Unrated calls first seen at or before `observed_before`, oldest first.
      def pending(observed_before:, max_lag_seconds:, limit: 5)
        @store.with do |db|
          db.exec_params(
            "WITH calls AS (#{CALLS}) SELECT c.signal_id, c.observed_at, c.channel, s.instrument, s.side, s.stop, " \
            "array_to_json(s.targets) AS targets FROM calls c JOIN #{S}.telegram_signals s ON s.id = c.signal_id " \
            "LEFT JOIN #{S}.telegram_signal_outcomes o ON o.signal_id = c.signal_id " \
            "WHERE o.signal_id IS NULL AND NOT (#{LATE}) AND c.observed_at <= $2 ORDER BY c.signal_id LIMIT $3",
            [max_lag_seconds, observed_before.iso8601(6), limit]
          ).map do |row|
            { "signal_id" => Integer(row["signal_id"], 10), "observed_at" => Time.parse(row["observed_at"]).utc, "channel" => row["channel"],
              "instrument" => row["instrument"], "side" => row["side"], "stop" => row["stop"], "targets" => JSON.parse(row["targets"]).map(&:to_s) }
          end
        end
      end

      def record_outcome(signal_id, outcome)
        raise ArgumentError, "outcome is invalid" unless OUTCOMES.include?(outcome["outcome"])
        @store.with do |db|
          db.exec_params(
            "INSERT INTO #{S}.telegram_signal_outcomes (signal_id, evaluated_at, outcome, horizon_hours, entry_at, entry_price, " \
            "exit_at, exit_price, return) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) ON CONFLICT (signal_id) DO NOTHING",
            [signal_id] + outcome.values_at("evaluated_at", "outcome", "horizon_hours", "entry_at", "entry_price", "exit_at", "exit_price", "return")
          )
        end
      end

      # One row per channel. `accuracy` is targets hit over targets plus stops hit, so it is
      # null until a call resolved either way; `rated` shows how small the sample is.
      def ratings(max_lag_seconds:)
        @store.with do |db|
          db.exec_params(
            "WITH calls AS (#{CALLS}), later AS (SELECT c.message_ref, bool_or(r.kind = 'edit') AS edited, bool_or(r.kind = 'deleted') AS deleted " \
            "FROM calls c JOIN #{S}.telegram_message_revisions r ON r.message_ref = c.message_ref AND r.revision > c.revision GROUP BY c.message_ref) " \
            "SELECT c.channel, (SELECT count(*) FROM #{S}.telegram_messages m WHERE m.channel = c.channel) AS messages, count(*) AS calls, " \
            "count(*) FILTER (WHERE #{LATE}) AS late, count(*) FILTER (WHERE o.signal_id IS NULL AND NOT (#{LATE})) AS pending, " \
            "#{OUTCOMES.map { |name| "count(*) FILTER (WHERE o.outcome = '#{name}') AS #{name}" }.join(', ')}, " \
            "avg(o.return) AS average_return, count(*) FILTER (WHERE l.edited) AS edited_after, count(*) FILTER (WHERE l.deleted) AS deleted_after " \
            "FROM calls c LEFT JOIN #{S}.telegram_signal_outcomes o ON o.signal_id = c.signal_id LEFT JOIN later l ON l.message_ref = c.message_ref " \
            "GROUP BY c.channel ORDER BY c.channel", [max_lag_seconds]
          ).map { |row| rating(row) }
        end
      end

      # Newest posts of a channel with every revision, its signal and the signal's outcome.
      def messages(channel, limit: 20)
        raise ArgumentError, "limit must be between 1 and #{ResearchStore::MAX_PAGE}" unless limit.is_a?(Integer) && (1..ResearchStore::MAX_PAGE).cover?(limit)
        @store.with do |db|
          posts = db.exec_params("SELECT id, message_id, published_at, first_seen_at, backfilled FROM #{S}.telegram_messages WHERE channel = $1 " \
                                 "ORDER BY message_id DESC LIMIT $2", [channel, limit]).to_a
          revisions = db.exec_params(
            "SELECT r.message_ref, r.revision, r.kind, r.observed_at, r.marked_edited, r.text, s.instrument, s.side, s.entry_low, s.entry_high, " \
            "s.stop, array_to_json(s.targets) AS targets, o.outcome, o.return FROM #{S}.telegram_message_revisions r " \
            "LEFT JOIN #{S}.telegram_signals s ON s.revision_id = r.id LEFT JOIN #{S}.telegram_signal_outcomes o ON o.signal_id = s.id " \
            "WHERE r.message_ref = ANY($1::bigint[]) ORDER BY r.message_ref, r.revision", ["{#{posts.map { |post| post['id'] }.join(',')}}"]
          ).group_by { |row| row["message_ref"] }
          posts.map do |post|
            { "channel" => channel, "message_id" => Integer(post["message_id"], 10), "published_at" => stamp(post["published_at"]),
              "first_seen_at" => stamp(post["first_seen_at"]),
              "backfilled" => post["backfilled"] == "t", "revisions" => revisions.fetch(post["id"], []).map { |row| revision(row) } }
          end
        end
      end

      private

      def revise(db, ref, number, kind, at, message, digest)
        id = db.exec_params(
          "INSERT INTO #{S}.telegram_message_revisions (message_ref, revision, kind, observed_at, marked_edited, text, text_digest) " \
          "VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id", [ref, number, kind, at, message["edited"] ? "t" : "f", message["text"], digest]
        ).first["id"]
        signal = kind == "deleted" ? nil : @parser.parse(message["text"])
        return 0 unless signal
        db.exec_params(
          "INSERT INTO #{S}.telegram_signals (revision_id, instrument, side, entry_low, entry_high, stop, targets, parser_version) " \
          "VALUES ($1, $2, $3, $4, $5, $6, $7::numeric[], $8)",
          [id] + signal.values_at("instrument", "side", "entry_low", "entry_high", "stop") + ["{#{signal['targets'].join(',')}}", signal["parser_version"]]
        )
        1
      end

      def rating(row)
        counts = row.slice("messages", "calls", "late", "pending", *OUTCOMES, "edited_after", "deleted_after").transform_values { |value| Integer(value, 10) }
        decided = counts["target"] + counts["stop"]
        rated = OUTCOMES.sum { |name| counts[name] } - counts["no_quote"]
        { "channel" => row["channel"] }.merge(counts).merge(
          "rated" => rated,
          "accuracy" => decided.zero? ? nil : (BigDecimal(counts["target"]) / decided).round(4).to_s("F"),
          "average_return" => row["average_return"] && BigDecimal(row["average_return"]).round(8).to_s("F")
        )
      end

      def revision(row)
        signal = row["instrument"] && row.slice("instrument", "side", "entry_low", "entry_high", "stop").merge(
          "targets" => JSON.parse(row["targets"]).map(&:to_s), "outcome" => row["outcome"], "return" => row["return"]
        )
        { "revision" => Integer(row["revision"], 10), "kind" => row["kind"], "observed_at" => stamp(row["observed_at"]),
          "marked_edited" => row["marked_edited"] == "t", "text" => row["text"], "signal" => signal }
      end

      def stamp(value)
        Time.parse(value).utc.iso8601(6)
      end
    end
  end
end
