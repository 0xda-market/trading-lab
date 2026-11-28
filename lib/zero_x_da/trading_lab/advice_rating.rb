# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "bigdecimal"
require "time"
require_relative "okx_candles"

module ZeroXDA
  module TradingLab
    # A counterfactual spot-long outcome, never an execution or a real account PnL.
    class AdviceRating
      MINUTE = 60_000
      VERSION = 1
      # OKX publishes a completed bar slightly after it closes. Until the settle
      # window passes, missing trailing bars mean "not yet", not "unverified".
      SETTLE_MS = 2 * MINUTE
      # Fixed-precision division keeps results identical across bigdecimal versions.
      BPS = BigDecimal(10_000)
      PRECISION = 32
      def initialize(candles: OkxCandles.new, clock: -> { Time.now.utc })
        @candles, @clock = candles, clock
      end

      def evaluate(advice)
        instrument = advice.fetch("instrument")
        raise ArgumentError, "spot USDT instrument required" unless /\A[A-Z0-9]{1,20}-USDT\z/.match?(instrument)
        issued = Time.iso8601(advice.fetch("issued_at"))
        horizon = advice.fetch("horizon_minutes")
        raise ArgumentError, "invalid horizon" unless horizon.is_a?(Integer) && (1..1440).cover?(horizon)
        low, high, stop, target, fee, slip = %w[entry_low entry_high stop target fee_bps slippage_bps].map do |key|
          value = advice.fetch(key)
          raise ArgumentError, "decimal string required" unless value.is_a?(String) && /\A\d{1,16}(?:\.\d{1,16})?\z/.match?(value)
          BigDecimal(value)
        end
        raise ArgumentError, "invalid levels or costs" unless stop.positive? && stop < low && low <= high && high < target && fee.between?(0, 100) && slip.between?(0, 100)
        first = ((issued.to_r * 1000).floor / MINUTE + 1) * MINUTE
        finish = first + horizon * MINUTE
        return {"state" => "pending"} if @clock.call.to_r * 1000 < finish + SETTLE_MS
        bars = @candles.range(instrument, "1m", first, finish - MINUTE)
        return result("unverified") unless bars.map { |b| b.fetch("start_ms") } == (first...finish).step(MINUTE).to_a
        entry = nil
        entry_at = nil
        bars.each do |bar|
          open = bar.fetch("open")
          if entry.nil?
            next unless open.between?(low, high)
            entry = open * (1 + rate(slip))
            # The entry is at the bar open; later intrabar ordering is unknown.
            entry_at = bar.fetch("start_ms")
          end
          # Stops fill no better than the open on a gap. Targets fill at the
          # target; a bar touching both is conservatively scored as a stop.
          if bar.fetch("low") <= stop
            return closed("stop", entry, [open, stop].min, fee, slip, entry_at, bar.fetch("start_ms"))
          elsif bar.fetch("high") >= target
            return closed("target", entry, target, fee, slip, entry_at, bar.fetch("start_ms"))
          end
        end
        return result("missed") unless entry
        closed("expired", entry, bars.last.fetch("close"), fee, slip, entry_at, bars.last.fetch("start_ms"))
      rescue OkxPublic::UnknownInstrument
        result("unverified")
      end

      private

      def rate(bps)
        bps.div(BPS, PRECISION)
      end

      def result(outcome)
        {"state" => "result", "outcome" => outcome, "rating_version" => VERSION}
      end

      def closed(outcome, entry, raw_exit, fee, slip, entry_at, exit_at)
        exit_price = raw_exit * (1 - rate(slip))
        net = (exit_price * (1 - rate(fee))).div(entry * (1 + rate(fee)), PRECISION) - 1
        result(outcome).merge("entry_price" => entry.to_s("F"), "exit_price" => exit_price.to_s("F"),
                              "entry_at_ms" => entry_at, "exit_bar_at_ms" => exit_at,
                              "net_return" => net.round(8).to_s("F"))
      end
    end
  end
end
