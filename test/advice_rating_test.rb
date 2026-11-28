# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/zero_x_da/trading_lab/advice_rating"

class AdviceRatingTest < Minitest::Test
  Lab = ZeroXDA::TradingLab
  ISSUED = Time.utc(2026, 1, 1)
  FIRST = ISSUED.to_i * 1000 + 60_000
  # Two one-minute bars: the window ends at ISSUED + 180s, then the settle window passes.
  SETTLED = ISSUED + 180 + 120

  def advice
    {"instrument" => "BTC-USDT", "issued_at" => ISSUED.iso8601, "horizon_minutes" => 2,
     "entry_low" => "99", "entry_high" => "101", "stop" => "95", "target" => "110",
     "fee_bps" => "10", "slippage_bps" => "5"}
  end

  def bar(index, open, high, low, close)
    {"start_ms" => FIRST + index * 60_000, "open" => BigDecimal(open), "high" => BigDecimal(high),
     "low" => BigDecimal(low), "close" => BigDecimal(close)}
  end

  # Serves the bars only for the exact causal window of the default advice.
  def rating(bars, now: SETTLED)
    source = Object.new
    source.define_singleton_method(:range) do |instrument, interval, first, last|
      raise "incorrect causal window" unless [instrument, interval, first, last] == ["BTC-USDT", "1m", FIRST, FIRST + 60_000]
      bars
    end
    Lab::AdviceRating.new(candles: source, clock: -> { now })
  end

  def evaluate(bars, **options)
    rating(bars, **options).evaluate(advice)
  end

  def refute_called_source
    Object.new.tap { |source| source.define_singleton_method(:range) { |*| raise "source must not be called" } }
  end

  def test_target_with_exact_costs
    r = evaluate([bar(0, "100", "111", "99", "110"), bar(1, "110", "112", "108", "111")])
    assert_equal({"state" => "result", "outcome" => "target", "rating_version" => 1,
                  "entry_price" => "100.05", "exit_price" => "109.945", "entry_at_ms" => FIRST,
                  "exit_bar_at_ms" => FIRST, "net_return" => "0.09670494"}, r)
  end

  def test_stop_with_exact_costs
    r = evaluate([bar(0, "100", "101", "94", "95"), bar(1, "95", "96", "94", "95")])
    assert_equal "stop", r["outcome"]
    assert_equal ["100.05", "94.9525", "-0.05284573"], r.values_at("entry_price", "exit_price", "net_return")
  end

  def test_gap_below_stop_exits_at_the_open_not_the_stop
    r = evaluate([bar(0, "100", "101", "99", "100"), bar(1, "90", "92", "88", "89")])
    assert_equal "stop", r["outcome"]
    assert_equal ["100.05", "89.955", "-0.10269595"], r.values_at("entry_price", "exit_price", "net_return")
    assert_equal [FIRST, FIRST + 60_000], r.values_at("entry_at_ms", "exit_bar_at_ms")
  end

  def test_gap_above_target_still_fills_at_the_target
    r = evaluate([bar(0, "100", "102", "99", "101"), bar(1, "115", "116", "114", "115")])
    assert_equal "target", r["outcome"]
    assert_equal ["109.945", "0.09670494"], r.values_at("exit_price", "net_return")
  end

  def test_bar_touching_both_stop_and_target_is_a_stop
    assert_equal "stop", evaluate([bar(0, "100", "111", "94", "100"), bar(1, "100", "102", "99", "101")])["outcome"]
  end

  def test_entry_on_a_later_bar_ignores_earlier_bars_outside_the_window
    # The first bar would have hit the stop level if it had been entered; it was not.
    r = evaluate([bar(0, "102", "105", "94", "103"), bar(1, "100", "101", "99", "103")])
    assert_equal "expired", r["outcome"]
    assert_equal [FIRST + 60_000, FIRST + 60_000], r.values_at("entry_at_ms", "exit_bar_at_ms")
    assert_equal "0.02691463", r["net_return"]
  end

  def test_entry_window_bounds_are_inclusive_and_exact
    low = evaluate([bar(0, "99", "100", "98", "99"), bar(1, "99", "100", "98", "99.5")])
    assert_equal ["expired", "99.0495", "0.00203987"], low.values_at("outcome", "entry_price", "net_return")
    high = evaluate([bar(0, "101", "102", "100", "101"), bar(1, "101", "102", "100", "101")])
    assert_equal "101.0505", high["entry_price"]
    assert_equal "missed", evaluate([bar(0, "101.01", "102", "100", "101"), bar(1, "101.01", "102", "100", "101")])["outcome"]
    assert_equal "missed", evaluate([bar(0, "98.99", "100", "98", "99"), bar(1, "98.99", "100", "98", "99")])["outcome"]
  end

  def test_missed_when_no_bar_opens_inside_the_window
    assert_equal "missed", evaluate([bar(0, "102", "105", "101", "103"), bar(1, "103", "106", "102", "104")])["outcome"]
  end

  def test_expired_exits_at_the_last_bar_close_and_names_that_bar
    r = evaluate([bar(0, "100", "102", "99", "101"), bar(1, "101", "104", "100", "103")])
    assert_equal ["expired", "102.9485", "0.02691463"], r.values_at("outcome", "exit_price", "net_return")
    assert_equal [FIRST, FIRST + 60_000], r.values_at("entry_at_ms", "exit_bar_at_ms")
  end

  def test_missing_or_misordered_bars_are_unverified
    assert_equal "unverified", evaluate([bar(0, "100", "111", "99", "110")])["outcome"]
    assert_equal "unverified", evaluate([bar(1, "100", "101", "99", "100"), bar(0, "100", "101", "99", "100")])["outcome"]
    assert_equal "unverified", evaluate([bar(0, "100", "101", "99", "100"), bar(0, "100", "101", "99", "100")])["outcome"]
  end

  def test_unknown_instrument_is_unverified_but_other_okx_errors_propagate
    unknown = Object.new
    unknown.define_singleton_method(:range) { |*| raise Lab::OkxPublic::UnknownInstrument, "unlisted" }
    assert_equal "unverified", Lab::AdviceRating.new(candles: unknown, clock: -> { SETTLED }).evaluate(advice)["outcome"]

    limited = Object.new
    limited.define_singleton_method(:range) { |*| raise Lab::OkxPublic::RateLimited, "slow down" }
    assert_raises(Lab::OkxPublic::RateLimited) { Lab::AdviceRating.new(candles: limited, clock: -> { SETTLED }).evaluate(advice) }
  end

  def test_pending_until_the_window_and_the_settle_period_have_passed
    assert_equal({"state" => "pending"}, rating([], now: ISSUED + 60).evaluate(advice))
    assert_equal({"state" => "pending"}, rating([], now: ISSUED + 180).evaluate(advice))
    assert_equal({"state" => "pending"}, rating([], now: SETTLED - 0.001r).evaluate(advice))
    assert_equal "result", rating([bar(0, "100", "102", "99", "101"), bar(1, "101", "104", "100", "103")], now: SETTLED).evaluate(advice)["state"]
  end

  def test_window_starts_at_the_first_full_minute_after_issue
    windows = []
    source = Object.new
    source.define_singleton_method(:range) { |_, _, first, last| windows << [first, last]; [] }
    rater = Lab::AdviceRating.new(candles: source, clock: -> { Time.utc(2026, 1, 2) })
    {"2026-01-01T00:00:00Z" => FIRST, "2026-01-01T00:00:30.500Z" => FIRST,
     "2026-01-01T00:00:59.999Z" => FIRST, "2026-01-01T00:01:00Z" => FIRST + 60_000,
     "2026-01-01T01:00:30+01:00" => FIRST}.each do |issued_at, first|
      windows.clear
      assert_equal "unverified", rater.evaluate(advice.merge("issued_at" => issued_at))["outcome"], issued_at
      assert_equal [[first, first + 60_000]], windows, issued_at
    end
  end

  def test_invalid_advice_is_rejected_before_any_candle_is_read
    rater = Lab::AdviceRating.new(candles: refute_called_source, clock: -> { SETTLED })
    {
      "instrument" => ["BTC-USDT-SWAP", "BTC-USD", "btc-usdt", "BTC-USDT-250101", "-USDT"],
      "horizon_minutes" => [0, 1441, "2", 2.0, nil],
      "stop" => ["99", "100", "0", "-1", 95, "1e2", ".5"],
      "entry_low" => ["102"],
      "entry_high" => ["98", "111"],
      "target" => ["101", "100"],
      "fee_bps" => ["101", "-1", 10],
      "slippage_bps" => ["100.01", "abc"],
      "issued_at" => ["yesterday", "2026-01-01"]
    }.each do |key, values|
      values.each do |value|
        assert_raises(ArgumentError, "#{key}=#{value.inspect}") { rater.evaluate(advice.merge(key => value)) }
      end
    end
    assert_raises(KeyError) { rater.evaluate(advice.reject { |key, _| key == "target" }) }
  end

  def test_the_rating_is_a_pure_function_of_advice_and_bars
    bars = [bar(0, "100", "111", "99", "110"), bar(1, "110", "112", "108", "111")]
    assert_equal evaluate(bars), evaluate(bars)
  end
end
