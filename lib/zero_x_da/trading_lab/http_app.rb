# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "json"
require "uri"
require_relative "replay"
require_relative "okx_lead_traders"
require_relative "leaderboard_cache"
require_relative "copy_replay"
require_relative "copy_quotes"
require_relative "research_store"
require_relative "market_tick_store"
require_relative "telegram_signal_store"

module ZeroXDA
  module TradingLab
    class HTTPApp
      MAX_BYTES = 65_536
      HEADERS = { "content-type" => "application/json; charset=utf-8", "cache-control" => "no-store" }.freeze

      LEADERS_PATH = "/v1/leaders/okx"
      COPY_PATH = "/v1/paper/copy-replays"
      REPLAY_PATH = "/v1/paper/replays"
      RUNS_PATH = "/v1/research/runs"
      MARKET_SESSIONS_PATH = "/v1/market/sessions"
      SIGNAL_RATINGS_PATH = "/v1/signals/telegram/ratings"
      SIGNAL_MESSAGES_PATH = "/v1/signals/telegram/messages"
      # Must match the collector's rating, or the two would disagree on which calls are late.
      SIGNAL_MAX_LAG_SECONDS = 300
      RUN_PATH = %r{\A/v1/research/runs/([1-9]\d{0,17})\z}
      MAX_QUERY_BYTES = 512

      def initialize(token: ENV.fetch("TRADING_LAB_SERVICE_TOKEN"), leaders: OkxLeadTraders.new, leaders_cache: LeaderboardCache.new,
                     positions_cache: LeaderboardCache.new(ttl_seconds: 300, max_entries: 32), quotes: CopyQuotes.new,
                     copies_cache: LeaderboardCache.new(ttl_seconds: 300, max_entries: 32), store: ResearchStore.from_env)
        raise ArgumentError, "TRADING_LAB_SERVICE_TOKEN is required" if token.to_s.empty?
        @token = token.to_s
        @leaders = leaders
        @leaders_cache = leaders_cache
        @positions_cache = positions_cache
        @quotes = quotes
        @copies_cache = copies_cache
        @store = store
      end

      def call(env)
        return reply(200, status: "ok") if env["REQUEST_METHOD"] == "GET" && env["PATH_INFO"] == "/health"
        route = [env["REQUEST_METHOD"], env["PATH_INFO"]]
        run_id = route.first == "GET" && RUN_PATH.match(route.last)&.captures&.first
        known = [["POST", REPLAY_PATH], ["GET", LEADERS_PATH], ["POST", COPY_PATH], ["GET", RUNS_PATH],
                 ["GET", MARKET_SESSIONS_PATH], ["GET", SIGNAL_RATINGS_PATH], ["GET", SIGNAL_MESSAGES_PATH]].include?(route)
        return reply(404, error: "not_found") unless known || run_id
        authorization = env["HTTP_AUTHORIZATION"].to_s
        provided = authorization.delete_prefix("Bearer ")
        return reply(401, error: "unauthorized") unless authorization.start_with?("Bearer ") && secure_equal?(provided, @token)
        return stored_run(Integer(run_id, 10)) if run_id
        return stored_runs(env["QUERY_STRING"].to_s) if route.last == RUNS_PATH
        return market_sessions(env["QUERY_STRING"].to_s) if route.last == MARKET_SESSIONS_PATH
        return signals(route.last, env["QUERY_STRING"].to_s) if [SIGNAL_RATINGS_PATH, SIGNAL_MESSAGES_PATH].include?(route.last)
        return leaders(env["QUERY_STRING"].to_s) if route.first == "GET"
        raw = env.fetch("rack.input").read(MAX_BYTES + 1)
        return reply(413, error: "payload_too_large") if raw.bytesize > MAX_BYTES
        document = JSON.parse(raw)
        return copy_replay(document) if route.last == COPY_PATH
        return reply(422, error: "invalid_request") unless document.is_a?(Hash) && document.key?("events") && (document.keys - %w[events options experiment]).empty?
        experiment = experiment(document)
        options = document.fetch("options", {})
        result = Replay.call(document["events"], options)
        portfolio = result.slice("ending_cash", "equity", "open_positions")
        run = record(kind: "paper_replay", options: options, input: document["events"], result: result, portfolio: portfolio, experiment: experiment)
        reply(200, { status: "ok", data: result }.merge(run))
      rescue ResearchStore::Unavailable
        reply(503, error: "store_unavailable")
      rescue JSON::ParserError
        reply(400, error: "invalid_json")
      rescue OkxLeadTraders::RateLimited
        reply(503, error: "upstream_rate_limited")
      rescue OkxLeadTraders::Error
        reply(502, error: "upstream_unavailable")
      rescue ArgumentError, KeyError => error
        reply(422, error: "invalid_request", message: error.message)
      end

      private

      # Paper copy of a lead trader's real closed OKX positions; nothing is ordered. Quoting a
      # copy reads many candle pages, so the computed result is cached for the positions'
      # lifetime. Recording is kept out of that cached computation: a write that failed is
      # retried by the next identical request instead of a null run_id being served for the
      # whole TTL, and a write that succeeded is reused, so one computation is one row.
      def copy_replay(document)
        valid = document.is_a?(Hash) && document["unique_code"].is_a?(String) && (document.keys - %w[unique_code options experiment]).empty?
        return reply(422, error: "invalid_request") unless valid
        code = document["unique_code"]
        raise ArgumentError, "unique_code is invalid" unless OkxLeadTraders::UNIQUE_CODE.match?(code)
        experiment = experiment(document)
        options = document.fetch("options", {})
        replay = CopyReplay.new(options)
        key = JSON.generate([code, options.transform_keys(&:to_s).sort, experiment])
        entry = @copies_cache.fetch(key) do
          available = @positions_cache.fetch(code) { @leaders.positions(code) }
          positions = replay.select(available)
          quotes = replay.quoted? ? @quotes.call(positions, replay.delay_ms) : nil
          result = replay.call(positions, quotes)
          portfolio = { "ending_cash" => result["equity"], "equity" => result["equity"], "open_positions" => {} }
          { data: { "unique_code" => code, "positions_available" => available.size }.merge(result), lock: Mutex.new, run_id: nil,
            run: { kind: "copy_replay", subject: code, options: options, input: positions, result: result, portfolio: portfolio, experiment: experiment } }
        end
        run = entry[:lock].synchronize do
          recorded = entry[:run_id] ? { run_id: entry[:run_id] } : record(**entry[:run])
          entry[:run_id] ||= recorded[:run_id]
          recorded
        end
        reply(200, { status: "ok", data: entry[:data] }.merge(run))
      end

      def experiment(document)
        name = document["experiment"]
        ResearchStore.validate_experiment(name)
        raise ResearchStore::Unavailable, "no store" if name && !@store
        name
      end

      # A simulation that cannot be stored is still a valid answer: it is returned with a null
      # run_id instead of being thrown away. Without a configured store nothing is added.
      def record(**run)
        return {} unless @store
        { run_id: @store.record_run(**run) }
      rescue ResearchStore::Unavailable
        raise if run[:experiment]
        { run_id: nil }
      end

      def stored_runs(raw_query)
        raise ResearchStore::Unavailable, "no store" unless @store
        return reply(414, error: "query_too_long") if raw_query.bytesize > MAX_QUERY_BYTES
        pairs = URI.decode_www_form(raw_query)
        query = pairs.to_h
        raise ArgumentError, "unknown or duplicate query parameter" unless pairs.size == query.size && (query.keys - %w[kind subject experiment limit before]).empty?
        filters = { kind: query["kind"], subject: query["subject"], experiment: query["experiment"] }
        filters[:limit] = whole(query["limit"], "limit") if query.key?("limit")
        filters[:before] = whole(query["before"], "before") if query.key?("before")
        reply(200, status: "ok", data: { "runs" => @store.runs(**filters) })
      end

      def stored_run(id)
        raise ResearchStore::Unavailable, "no store" unless @store
        run = @store.run(id)
        run ? reply(200, status: "ok", data: run) : reply(404, error: "not_found")
      end

      # Coverage of the collected quotes: each session is one live connection, newest first.
      def market_sessions(raw_query)
        raise ResearchStore::Unavailable, "no store" unless @store
        return reply(414, error: "query_too_long") if raw_query.bytesize > MAX_QUERY_BYTES
        pairs = URI.decode_www_form(raw_query)
        raise ArgumentError, "unknown or duplicate query parameter" unless pairs.map(&:first).then { |keys| keys.uniq == keys && (keys - %w[limit]).empty? }
        limit = pairs.empty? ? 20 : whole(pairs.first.last, "limit")
        reply(200, status: "ok", data: { "sessions" => MarketTickStore.new(@store).sessions(limit: limit) })
      end

      # Collected Telegram calls: per-channel accuracy, or one channel's posts with every revision.
      def signals(path, raw_query)
        raise ResearchStore::Unavailable, "no store" unless @store
        return reply(414, error: "query_too_long") if raw_query.bytesize > MAX_QUERY_BYTES
        pairs = URI.decode_www_form(raw_query)
        query = pairs.to_h
        allowed = path == SIGNAL_RATINGS_PATH ? [] : %w[channel limit]
        raise ArgumentError, "unknown or duplicate query parameter" unless pairs.size == query.size && (query.keys - allowed).empty?
        store = TelegramSignalStore.new(@store)
        return reply(200, status: "ok", data: { "max_lag_seconds" => SIGNAL_MAX_LAG_SECONDS, "ratings" => store.ratings(max_lag_seconds: SIGNAL_MAX_LAG_SECONDS) }) if allowed.empty?
        channel = TelegramPreview.channel(query.fetch("channel") { raise ArgumentError, "channel is required" })
        limit = query.key?("limit") ? whole(query["limit"], "limit") : 20
        reply(200, status: "ok", data: { "messages" => store.messages(channel, limit: limit) })
      end

      def whole(value, name)
        raise ArgumentError, "#{name} must be a whole number" unless /\A\d{1,18}\z/.match?(value.to_s)
        Integer(value, 10)
      end

      # Read-only public leaderboard. Options are validated by OkxLeadTraders before any upstream call.
      def leaders(raw_query)
        return reply(414, error: "query_too_long") if raw_query.bytesize > MAX_QUERY_BYTES
        pairs = URI.decode_www_form(raw_query)
        keys = pairs.map(&:first)
        raise ArgumentError, "duplicate query parameter" unless keys.uniq.size == keys.size
        options = pairs.to_h
        key = options.sort.map { |name, value| "#{name}=#{value}" }.join("&")
        reply(200, status: "ok", data: @leaders_cache.fetch(key) { @leaders.ranks(options) })
      end

      def secure_equal?(a, b)
        return false if a.empty? || a.bytesize != b.bytesize
        a.bytes.zip(b.bytes).reduce(0) { |value, (left, right)| value | (left ^ right) }.zero?
      end

      def reply(status, body)
        [status, HEADERS, [JSON.generate(body)]]
      end
    end
  end
end
