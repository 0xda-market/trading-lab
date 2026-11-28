# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/zero_x_da/trading_lab/advice_rating"

class AdviceRatingTest < Minitest::Test
  Lab = ZeroXDA::TradingLab
  ISSUED = Time.utc(2026, 1, 1)
  FIRST = ISSUED.to_i * 1000 + 60_000
  def advice
    {"instrument"=>"BTC-USDT", "issued_at"=>ISSUED.iso8601, "horizon_minutes"=>2,
     "entry_low"=>"99", "entry_high"=>"101", "stop"=>"95", "target"=>"110", "fee_bps"=>"10", "slippage_bps"=>"5"}
  end
  def bar(i, open, high, low, close)
    {"start_ms"=>FIRST+i*60_000, "open"=>BigDecimal(open), "high"=>BigDecimal(high), "low"=>BigDecimal(low), "close"=>BigDecimal(close)}
  end
  def rating(bars, now: ISSUED+180)
    source = Object.new
    source.define_singleton_method(:range) { |instrument, interval, first, last|
      raise "incorrect causal window" unless [instrument, interval, first, last] == ["BTC-USDT", "1m", FIRST, FIRST+60_000]
      bars
    }
    Lab::AdviceRating.new(candles: source, clock: -> { now })
  end
  def test_target_and_costs
    r = rating([bar(0,"100","111","99","110"), bar(1,"110","112","108","111")]).evaluate(advice)
    assert_equal "target", r["outcome"]
    assert_operator BigDecimal(r["net_return"]), :<, BigDecimal("0.1")
    assert_operator BigDecimal(r["net_return"]), :>, 0
  end
  def test_ambiguous_bar_is_stop
    assert_equal "stop", rating([bar(0,"100","111","94","100"), bar(1,"100","102","99","101")]).evaluate(advice)["outcome"]
  end
  def test_missing_bar_is_unverified
    assert_equal "unverified", rating([bar(0,"100","111","99","110")]).evaluate(advice)["outcome"]
  end
  def test_pending_missed_and_expired
    assert_equal "pending", rating([], now: ISSUED+60).evaluate(advice)["state"]
    assert_equal "missed", rating([bar(0,"102","105","101","103"),bar(1,"103","106","102","104")]).evaluate(advice)["outcome"]
    assert_equal "expired", rating([bar(0,"100","102","99","101"),bar(1,"101","104","100","103")]).evaluate(advice)["outcome"]
  end
  def test_derivatives_rejected
    assert_raises(ArgumentError) { rating([]).evaluate(advice.merge("instrument"=>"BTC-USDT-SWAP")) }
  end
end
