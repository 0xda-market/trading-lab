# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "time"
require_relative "research_store"

module ZeroXDA
  module TradingLab
    # Collected market ticks and the stream sessions that bound their coverage.
    class MarketTickStore
      S = ResearchStore::SCHEMA
      COLUMNS = %w[instrument received_at exchange_event_at price bid ask bid_size ask_size].freeze

      def initialize(store)
        @store = store
      end

      # Starts a session. Sessions an earlier process left open are closed first, at their
      # last tick: after a crash nothing later than that is known to have been observed.
      def open_session(source, instruments, at)
        @store.with do |db|
          db.exec_params(
            "UPDATE #{S}.market_stream_sessions s SET end_reason = 'abandoned', ended_at = COALESCE(" \
            "(SELECT max(received_at) FROM #{S}.market_ticks t WHERE t.session_id = s.id), s.connected_at) " \
            "WHERE s.source = $1 AND s.ended_at IS NULL", [source]
          )
          row = db.exec_params(
            "INSERT INTO #{S}.market_stream_sessions (source, instruments, connected_at) VALUES ($1, $2::text[], $3) RETURNING id",
            [source, "{#{instruments.join(',')}}", at.iso8601(6)]
          ).first
          Integer(row.fetch("id"), 10)
        end
      end

      def close_session(id, at, reason)
        @store.with do |db|
          db.exec_params("UPDATE #{S}.market_stream_sessions SET ended_at = GREATEST($2::timestamptz, connected_at), end_reason = $3 " \
                         "WHERE id = $1 AND ended_at IS NULL", [id, at.iso8601(6), reason.to_s[0, 200]])
        end
      end

      # Appends ticks in the order given, which is collection order, in one statement.
      def insert(session_id, ticks)
        return 0 if ticks.empty?
        values = ticks.each_index.map do |row|
          base = row * COLUMNS.size + 1
          "($1, #{(1..COLUMNS.size).map { |offset| "$#{base + offset}" }.join(', ')})"
        end
        params = [session_id] + ticks.flat_map { |tick| tick.values_at(*COLUMNS) }
        @store.with do |db|
          db.transaction do
            db.exec_params("INSERT INTO #{S}.market_ticks (session_id, instrument, received_at, exchange_at, last, bid, ask, " \
                           "bid_size, ask_size) VALUES #{values.join(', ')}", params)
            db.exec_params("UPDATE #{S}.market_stream_sessions SET ticks = ticks + $2 WHERE id = $1", [session_id, ticks.size])
          end
        end
        ticks.size
      end

      # Newest first. The time between one session's ended_at and the next connected_at is a
      # gap with no observations; an open session has a null ended_at.
      def sessions(limit: 20)
        raise ArgumentError, "limit must be between 1 and #{ResearchStore::MAX_PAGE}" unless limit.is_a?(Integer) && (1..ResearchStore::MAX_PAGE).cover?(limit)
        @store.with do |db|
          db.exec_params("SELECT id, source, array_to_json(instruments) AS instruments, connected_at, ended_at, end_reason, ticks " \
                         "FROM #{S}.market_stream_sessions ORDER BY id DESC LIMIT $1", [limit]).map do |row|
            { "id" => Integer(row["id"], 10), "source" => row["source"], "instruments" => JSON.parse(row["instruments"]),
              "connected_at" => stamp(row["connected_at"]), "ended_at" => stamp(row["ended_at"]),
              "end_reason" => row["end_reason"], "ticks" => Integer(row["ticks"], 10) }
          end
        end
      end

      # Ticks of one instrument received in from..to, in collection order.
      def ticks(instrument, from:, to:, limit: 1000)
        raise ArgumentError, "limit must be between 1 and 10000" unless limit.is_a?(Integer) && (1..10_000).cover?(limit)
        @store.with do |db|
          db.exec_params("SELECT id, session_id, instrument, received_at, exchange_at, last, bid, ask FROM #{S}.market_ticks " \
                         "WHERE instrument = $1 AND received_at >= $2 AND received_at <= $3 ORDER BY id LIMIT $4",
                         [instrument, from.iso8601(6), to.iso8601(6), limit]).map do |row|
            { "id" => Integer(row["id"], 10), "session_id" => Integer(row["session_id"], 10), "instrument" => row["instrument"],
              "received_at" => stamp(row["received_at"]), "exchange_event_at" => stamp(row["exchange_at"]),
              "price" => row["last"], "bid" => row["bid"], "ask" => row["ask"] }
          end
        end
      end

      private

      def stamp(value)
        value && Time.parse(value).utc.iso8601(6)
      end
    end
  end
end
