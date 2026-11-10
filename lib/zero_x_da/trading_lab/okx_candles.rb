# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "bigdecimal"
require_relative "okx_public"

module ZeroXDA
  module TradingLab
    # Read-only client for public OKX candlesticks (GET /api/v5/market/history-candles).
    # Only completed bars are returned, so a caller can never price against a bar that was
    # still forming when it was read.
    class OkxCandles
      PATH = "/api/v5/market/history-candles"
      BARS = { "1m" => 60_000, "5m" => 300_000, "15m" => 900_000, "1H" => 3_600_000, "4H" => 14_400_000 }.freeze
      PAGE = 100
      INSTRUMENT = /\A[A-Z0-9]{1,20}-[A-Z0-9]{2,10}(?:-SWAP)?\z/
      # Documented limit: 20 requests per 2 seconds per IP.
      MIN_INTERVAL_SECONDS = 0.12
      SHARED_THROTTLE = { lock: Mutex.new, last_request_at: nil }
      PRICE = /\A\d+(?:\.\d+)?(?:[eE][-+]?\d{1,3})?\z/

      def self.requests_for(bars)
        (bars + PAGE - 1) / PAGE
      end

      def initialize(okx: OkxPublic.new(throttle: SHARED_THROTTLE, min_interval: MIN_INTERVAL_SECONDS))
        @okx = okx
      end

      # Completed bars whose start lies in from_ms..to_ms, oldest first, as
      # { "start_ms", "open", "high", "low", "close" } with BigDecimal prices.
      def range(instrument, bar, from_ms, to_ms)
        width = BARS[bar]
        raise ArgumentError, "bar must be one of #{BARS.keys.join(', ')}" unless width
        raise ArgumentError, "instrument is invalid" unless INSTRUMENT.match?(instrument.to_s)
        raise ArgumentError, "candle range is invalid" unless from_ms.is_a?(Integer) && to_ms.is_a?(Integer) && from_ms.positive? && from_ms <= to_ms
        bars = {}
        after = to_ms + 1
        loop do
          query = { "instId" => instrument.to_s, "bar" => bar, "after" => after.to_s, "before" => (from_ms - 1).to_s, "limit" => PAGE.to_s }
          page = @okx.data(PATH, query, rows: Array).map { |row| candle(row, width, from_ms, after) }
          break if page.empty?
          page.each { |row| bars[row["start_ms"]] = row if row.delete("confirmed") }
          oldest = page.map { |row| row["start_ms"] }.min
          break if page.size < PAGE || oldest <= from_ms
          after = oldest
        end
        bars.values.sort_by { |row| row["start_ms"] }
      end

      private

      def candle(row, width, from_ms, after)
        valid = row.size >= 9 && row.all?(String) && /\A\d{13}\z/.match?(row[0]) && row[1..4].all? { |value| PRICE.match?(value) }
        raise OkxPublic::Error, "OKX candle is invalid" unless valid
        start = Integer(row[0], 10)
        # A bar outside the asked window or off the grid would silently shift a fill in time.
        raise OkxPublic::Error, "OKX candle is outside the requested range" unless start >= from_ms && start < after && (start % width).zero?
        open, high, low, close = row[1..4].map { |value| BigDecimal(value) }
        raise OkxPublic::Error, "OKX candle prices are inconsistent" unless low.positive? && low <= [open, close].min && high >= [open, close].max
        { "start_ms" => start, "open" => open, "high" => high, "low" => low, "close" => close, "confirmed" => row[8] == "1" }
      end
    end
  end
end
