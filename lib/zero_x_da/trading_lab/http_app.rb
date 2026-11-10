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

module ZeroXDA
  module TradingLab
    class HTTPApp
      MAX_BYTES = 65_536
      HEADERS = { "content-type" => "application/json; charset=utf-8", "cache-control" => "no-store" }.freeze

      LEADERS_PATH = "/v1/leaders/okx"
      COPY_PATH = "/v1/paper/copy-replays"
      MAX_QUERY_BYTES = 512

      def initialize(token: ENV.fetch("TRADING_LAB_SERVICE_TOKEN"), leaders: OkxLeadTraders.new, leaders_cache: LeaderboardCache.new,
                     positions_cache: LeaderboardCache.new(ttl_seconds: 300, max_entries: 32), quotes: CopyQuotes.new,
                     copies_cache: LeaderboardCache.new(ttl_seconds: 300, max_entries: 32))
        raise ArgumentError, "TRADING_LAB_SERVICE_TOKEN is required" if token.to_s.empty?
        @token = token.to_s
        @leaders = leaders
        @leaders_cache = leaders_cache
        @positions_cache = positions_cache
        @quotes = quotes
        @copies_cache = copies_cache
      end

      def call(env)
        return reply(200, status: "ok") if env["REQUEST_METHOD"] == "GET" && env["PATH_INFO"] == "/health"
        route = [env["REQUEST_METHOD"], env["PATH_INFO"]]
        return reply(404, error: "not_found") unless [["POST", "/v1/paper/replays"], ["GET", LEADERS_PATH], ["POST", COPY_PATH]].include?(route)
        authorization = env["HTTP_AUTHORIZATION"].to_s
        provided = authorization.delete_prefix("Bearer ")
        return reply(401, error: "unauthorized") unless authorization.start_with?("Bearer ") && secure_equal?(provided, @token)
        return leaders(env["QUERY_STRING"].to_s) if route.first == "GET"
        raw = env.fetch("rack.input").read(MAX_BYTES + 1)
        return reply(413, error: "payload_too_large") if raw.bytesize > MAX_BYTES
        document = JSON.parse(raw)
        return copy_replay(document) if route.last == COPY_PATH
        return reply(422, error: "invalid_request") unless document.is_a?(Hash) && document.key?("events") && (document.keys - %w[events options]).empty?
        reply(200, status: "ok", data: Replay.call(document["events"], document.fetch("options", {})))
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
      # copy reads many candle pages, so a finished result is kept for the positions' lifetime.
      def copy_replay(document)
        valid = document.is_a?(Hash) && document["unique_code"].is_a?(String) && (document.keys - %w[unique_code options]).empty?
        return reply(422, error: "invalid_request") unless valid
        code = document["unique_code"]
        raise ArgumentError, "unique_code is invalid" unless OkxLeadTraders::UNIQUE_CODE.match?(code)
        options = document.fetch("options", {})
        replay = CopyReplay.new(options)
        key = JSON.generate([code, options.transform_keys(&:to_s).sort])
        data = @copies_cache.fetch(key) do
          available = @positions_cache.fetch(code) { @leaders.positions(code) }
          positions = replay.select(available)
          quotes = replay.quoted? ? @quotes.call(positions, replay.delay_ms) : nil
          { "unique_code" => code, "positions_available" => available.size }.merge(replay.call(positions, quotes))
        end
        reply(200, status: "ok", data: data)
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
