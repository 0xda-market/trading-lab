# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "bigdecimal"
require "time"
require_relative "okx_candles"

module ZeroXDA
  module TradingLab
    # Judges a channel's calls against the market that followed them.
    #
    # A call is entered at the open of the first completed one-minute OKX bar after the lab
    # saw it plus the follower delay: the same causal rule as the copy replay, so a call is
    # never credited with a price from before it could be read. From there the bars are
    # walked for up to `horizon_hours`: the first target or the stop, whichever the price
    # reaches first, decides it. A bar that touches both counts as the stop.
    #
    # The return is the raw price move in the call's direction, without fees or slippage: it
    # measures whether the channel was right, not what a follower would have earned.
    class SignalRating
      MINUTE = 60_000
      TOLERANCE_BARS = 5
      MAX_HORIZON_HOURS = 168

      def initialize(signals:, candles: OkxCandles.new, clock: -> { Time.now.utc }, horizon_hours: 24, delay_seconds: 5, max_lag_seconds: 300)
        raise ArgumentError, "horizon_hours must be 1..#{MAX_HORIZON_HOURS}" unless horizon_hours.is_a?(Integer) && (1..MAX_HORIZON_HOURS).cover?(horizon_hours)
        raise ArgumentError, "delay_seconds must be 0..3600" unless delay_seconds.is_a?(Integer) && (0..3600).cover?(delay_seconds)
        raise ArgumentError, "max_lag_seconds must be 1..86400" unless max_lag_seconds.is_a?(Integer) && (1..86_400).cover?(max_lag_seconds)
        @signals = signals
        @candles = candles
        @clock = clock
        @horizon = horizon_hours
        @delay = delay_seconds
        @max_lag = max_lag_seconds
      end

      attr_reader :max_lag

      # Rates calls whose whole horizon is already history, so an outcome is final when it is
      # written and never depends on when the rating ran. Returns how many were rated.
      def evaluate_pending(limit: 5)
        now = @clock.call
        # The horizon's last bar must be complete: one bar for the entry, one for the close.
        ready = now - @horizon * 3600 - @delay - 2 * 60
        calls = @signals.pending(observed_before: ready, max_lag_seconds: @max_lag, limit: limit)
        calls.each { |call| @signals.record_outcome(call["signal_id"], evaluate(call).merge("evaluated_at" => now.iso8601(6), "horizon_hours" => @horizon)) }
        calls.size
      end

      def evaluate(call)
        long = call["side"] == "long"
        seen_ms = (call["observed_at"].to_r * 1000).ceil
        first = ((seen_ms + @delay * 1000 + MINUTE - 1) / MINUTE) * MINUTE
        bars = @candles.range(call["instrument"], "1m", first, first + @horizon * 60 * MINUTE)
        entry_bar = bars.find { |bar| bar["start_ms"] < first + TOLERANCE_BARS * MINUTE }
        return { "outcome" => "no_quote" } unless entry_bar
        entry = entry_bar["open"]
        stop = call["stop"] && BigDecimal(call["stop"])
        # Targets are stored nearest first; the first one decides the call.
        target = call["targets"].first && BigDecimal(call["targets"].first)
        result = { "entry_at" => iso(entry_bar["start_ms"]), "entry_price" => entry.to_s("F") }
        # The market had already passed the stop or the target before the call could be read.
        gone = (stop && (long ? entry <= stop : entry >= stop)) || (target && (long ? entry >= target : entry <= target))
        return result.merge("outcome" => "missed") if gone
        bars.drop_while { |bar| bar["start_ms"] < entry_bar["start_ms"] }.each do |bar|
          return close(result, "stop", bar["start_ms"], stop, entry, long) if stop && (long ? bar["low"] <= stop : bar["high"] >= stop)
          return close(result, "target", bar["start_ms"], target, entry, long) if target && (long ? bar["high"] >= target : bar["low"] <= target)
        end
        last = bars.last
        close(result, "expired", last["start_ms"] + MINUTE, last["close"], entry, long)
      rescue OkxPublic::UnknownInstrument
        { "outcome" => "no_quote" }
      end

      private

      def close(result, outcome, at_ms, price, entry, long)
        change = price / entry - 1
        result.merge("outcome" => outcome, "exit_at" => iso(at_ms), "exit_price" => price.to_s("F"),
                     "return" => (long ? change : -change).round(8).to_s("F"))
      end

      def iso(at_ms)
        Time.at(Rational(at_ms, 1000)).utc.iso8601(3)
      end
    end
  end
end
