# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/zero_x_da/trading_lab/copy_quotes"
require_relative "../lib/zero_x_da/trading_lab/copy_replay"
require_relative "support/fake_candles"

class CopyQuotesTest < Minitest::Test
  Lab = ZeroXDA::TradingLab
  M = 60_000
  T0 = 1_761_999_600_000 # a 4H bar boundary

  def position(id, side, opened, closed, open_price: "100", close_price: "110", instrument: "BTC-USDT-SWAP")
    { "sub_position_id" => id, "instrument" => instrument, "side" => side, "open_price" => open_price, "close_price" => close_price,
      "opened_at_ms" => opened, "closed_at_ms" => closed, "opened_at" => "o#{id}", "closed_at" => "c#{id}" }
  end

  def quote(positions, candles, delay_ms: 5000, **limits)
    Lab::CopyQuotes.new(candles: candles, **limits).call(positions, delay_ms)
  end

  def test_fills_at_the_first_minute_open_after_the_signal_and_the_delay
    candles = FakeCandles.new(T0 => "100", T0 + M => "104", T0 + 10 * M => "110", T0 + 11 * M => "108")
    # Signal 1 s into a minute: the leader got 100, the follower's first quote is the next open.
    result = quote([position("1", "long", T0 + 1000, T0 + 9 * M + 58_000)], candles)
    quote = result["quotes"].fetch(0)
    assert_equal [T0 + M, BigDecimal("104")], quote["entry"]
    # 58 s + 5 s delay crosses the minute, so the exit is one bar later than the leader's.
    assert_equal [T0 + 11 * M, BigDecimal("108")], quote["exit"]
    assert_equal "1m", result["mark_bar"]
    assert_equal (1..10).map { |step| T0 + step * M }, quote["path"].map(&:first)
    assert_equal [BigDecimal("110"), BigDecimal("108"), BigDecimal("108")], quote["path"].last.drop(1)
  end

  def test_a_signal_exactly_on_a_minute_with_no_delay_takes_that_open
    candles = FakeCandles.new(T0 => "100", T0 + M => "105")
    quote = quote([position("1", "long", T0, T0 + M)], candles, delay_ms: 0)["quotes"].fetch(0)
    assert_equal [[T0, BigDecimal("100")], [T0 + M, BigDecimal("105")]], quote.values_at("entry", "exit")
  end

  def test_missing_minutes_are_bridged_only_within_the_tolerance
    gap = (1..3).map { |step| T0 + step * M }
    bridged = quote([position("1", "long", T0 + 1000, T0 + 20 * M)], FakeCandles.new({ T0 => "100" }, missing: gap))
    assert_equal T0 + 4 * M, bridged["quotes"].fetch(0)["entry"].first
    wide = (1..5).map { |step| T0 + step * M }
    assert_empty quote([position("1", "long", T0 + 1000, T0 + 20 * M)], FakeCandles.new({ T0 => "100" }, missing: wide))["quotes"]
    gone = quote([position("1", "long", T0, T0 + M, instrument: "GONE-USDT-SWAP")], FakeCandles.new({ T0 => "1" }, unknown: ["GONE-USDT-SWAP"]))
    assert_empty gone["quotes"]
  end

  def test_nearby_fills_share_requests_and_long_holds_use_a_coarser_path
    candles = FakeCandles.new(T0 => "100")
    near = [position("1", "long", T0, T0 + 30 * M), position("2", "short", T0 + 10 * M, T0 + 40 * M)]
    result = quote(near, candles)
    assert_equal 1, candles.calls.count { |call| call[1] == "1m" && call[3] - call[2] == 99 * M }
    assert_equal 2, result["requests"]

    long_hold = [position("1", "long", T0 + 1000, T0 + 30 * 24 * 60 * M)]
    coarse = quote(long_hold, FakeCandles.new(T0 => "100"), max_requests: 12)
    assert_equal "1H", coarse["mark_bar"]
    path = coarse["quotes"].fetch(0)["path"]
    assert_equal T0 + M, path.first.first, "the bar that began before the entry is stamped at the entry"
    assert_nil path.last[3], "a bar ending after the exit has no close the follower could see"
    assert_operator coarse["requests"], :<=, 12
  end

  def test_refuses_to_exceed_the_request_budget
    far = (0..5).map { |step| position(step.to_s, "long", T0 + step * 200 * M, T0 + step * 200 * M + M) }
    error = assert_raises(ArgumentError) { quote(far, FakeCandles.new(T0 => "100"), max_requests: 3) }
    assert_match(/max_positions/, error.message)
    assert_raises(ArgumentError) { quote([position("1", "long", T0, T0 + 90 * 24 * 60 * M)], FakeCandles.new(T0 => "1"), max_requests: 3) }
  end

  def test_replay_uses_the_follower_quotes_not_the_leader_prices
    # The leader is filled at 100 and closes at 110 (+10 %). Price has already run to 104 by
    # the follower's first quote and falls back to 108 by the follower's exit.
    candles = FakeCandles.new(T0 => "100", T0 + M => "104", T0 + 5 * M => "90", T0 + 6 * M => "104", T0 + 10 * M => "110", T0 + 11 * M => "108")
    positions = [position("1", "long", T0 + 1000, T0 + 9 * M + 58_000)]
    replay = Lab::CopyReplay.new("fee_bps" => "0", "slippage_bps" => "0")
    result = replay.call(positions, quote(positions, candles, delay_ms: replay.delay_ms))
    trade = result["trades"].first
    assert_equal %w[104.0 108.0 100.0 110.0], trade.values_at("entry", "exit", "leader_entry", "leader_exit")
    assert_equal ["2025-11-01T12:21:00.000Z", "2025-11-01T12:31:00.000Z"], trade.values_at("entry_at", "exit_at")
    expected = (BigDecimal("100") * (BigDecimal("108") / 104 - 1)).round(8).to_s("F")
    assert_equal [expected, "10.0"], [trade["pnl"], result["baseline_pnl"]]
    assert_equal (BigDecimal("10") - BigDecimal(expected)).to_s("F"), result["delay_drag"]
    # The dip to 90 never shows in the closed trade, only in the marked drawdown.
    dip = (BigDecimal("100") * (1 - BigDecimal("90") / 104) / 1000).round(8).to_s("F")
    assert_equal [dip, "0.0"], result.values_at("max_drawdown", "max_drawdown_realized")
    assert_equal ["quotes", 5, "1m"], result.values_at("pricing", "follower_delay_seconds", "mark_bar")
  end

  def test_replay_liquidates_a_short_when_the_path_doubles_and_counts_missing_quotes
    candles = FakeCandles.new({ T0 => "100", T0 + 3 * M => "250", T0 + 4 * M => "100" }, unknown: ["GONE-USDT-SWAP"])
    positions = [position("1", "short", T0, T0 + 8 * M, close_price: "100"), position("2", "long", T0, T0 + M, instrument: "GONE-USDT-SWAP")]
    replay = Lab::CopyReplay.new("fee_bps" => "0", "slippage_bps" => "0", "follower_delay_seconds" => 0)
    result = replay.call(positions, quote(positions, candles, delay_ms: 0))
    assert_equal [1, 1, { "no_quote" => 1 }, 1], result.values_at("copied", "rejected", "rejections", "liquidated")
    trade = result["trades"].first
    assert_equal [true, "-100.0", "200.0"], trade.values_at("liquidated", "pnl", "exit")
    assert_equal ["900.0", "0.1"], result.values_at("equity", "max_drawdown")
    assert_equal "0.0", result["baseline_pnl"], "the leader survived the same spike"
  end

  def test_replay_rejects_quotes_that_precede_their_signal
    positions = [position("1", "long", T0 + 1000, T0 + 2 * M)]
    early = { "mark_bar" => nil, "quotes" => { 0 => { "entry" => [T0, "100"], "exit" => [T0 + 3 * M, "100"], "path" => [] } } }
    assert_raises(ArgumentError) { Lab::CopyReplay.call(positions, {}, early) }
    assert_raises(ArgumentError) { Lab::CopyReplay.call(positions) }
    assert_raises(ArgumentError) { Lab::CopyReplay.new("follower_delay_seconds" => 3601) }
    assert_raises(ArgumentError) { Lab::CopyReplay.new("pricing" => "hindsight") }
    assert_equal 2, Lab::CopyReplay.new("max_positions" => "2").select([1, 2, 3]).size
  end
end
