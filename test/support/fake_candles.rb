# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "bigdecimal"
require_relative "../../lib/zero_x_da/trading_lab/okx_candles"

# Deterministic stand-in for OkxCandles: `prices` maps a minute start to the price that
# minute opens at, held until the next listed minute. Wider bars aggregate the minutes.
class FakeCandles
  MINUTE = 60_000
  attr_reader :calls

  # Prices may be passed bare (`FakeCandles.new(T0 => "100")`), which Ruby reads as keywords.
  def initialize(prices = nil, missing: [], unknown: [], **bare)
    @prices = (prices || bare).sort.to_h
    @missing = missing
    @unknown = unknown
    @calls = []
  end

  def range(instrument, bar, from_ms, to_ms)
    @calls << [instrument, bar, from_ms, to_ms]
    raise ZeroXDA::TradingLab::OkxPublic::UnknownInstrument, "gone" if @unknown.include?(instrument)
    width = ZeroXDA::TradingLab::OkxCandles::BARS.fetch(bar)
    first = ((from_ms + width - 1) / width) * width
    (first..to_ms).step(width).filter_map do |start|
      minutes = (start...(start + width)).step(MINUTE).reject { |minute| @missing.include?(minute) }
      next if minutes.empty?
      values = minutes.flat_map { |minute| [at(minute), at(minute + MINUTE)] }
      { "start_ms" => start, "open" => at(minutes.first), "high" => values.max, "low" => values.min, "close" => at(minutes.last + MINUTE) }
    end
  end

  private

  def at(minute)
    BigDecimal(@prices.select { |start, _| start <= minute }.values.last || @prices.values.first)
  end
end
