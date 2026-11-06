# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "minitest/autorun"
require "bigdecimal"
require_relative "../lib/zero_x_da/trading_lab/copy_replay"

class CopyReplayTest < Minitest::Test
  def position(id, side, open_price, close_price, opened, closed)
    { "sub_position_id" => id, "instrument" => "BTC-USDT-SWAP", "side" => side,
      "open_price" => open_price, "close_price" => close_price,
      "opened_at_ms" => opened, "closed_at_ms" => closed,
      "opened_at" => "t#{opened}", "closed_at" => "t#{closed}" }
  end

  def replay(positions, options = {})
    ZeroXDA::TradingLab::CopyReplay.call(positions, options)
  end

  def test_frictionless_long_and_short_match_the_leader_prices
    result = replay([position("1", "long", "100", "110", 1, 2), position("2", "short", "100", "90", 3, 4)],
                    "fee_bps" => "0", "slippage_bps" => "0")
    assert_equal %w[10.0 10.0], result["trades"].map { |trade| trade["pnl"] }
    assert_equal "1020.0", result["equity"]
    assert_equal "20.0", result["baseline_pnl"]
    assert_equal "0.0", result["cost_drag"]
    assert_equal [2, 0], [result["wins"], result["losses"]]
  end

  def test_costs_move_prices_against_the_follower_and_charge_both_sides
    result = replay([position("1", "long", "100", "110", 1, 2)], "fee_bps" => "10", "slippage_bps" => "100")
    trade = result["trades"].first
    assert_equal ["101.0", "108.9"], [trade["entry"], trade["exit"]]
    gross = BigDecimal("100") * (BigDecimal("108.9") / BigDecimal("101") - 1)
    expected = gross - BigDecimal("0.1") - (BigDecimal("100") + gross) * BigDecimal("0.001")
    assert_equal expected.round(8).to_s("F"), trade["pnl"]
    assert_operator BigDecimal(result["cost_drag"]), :>, 0
  end

  def test_rejects_copies_without_free_cash_and_releases_cash_on_close_first
    positions = [position("1", "long", "1", "1", 1, 10), position("2", "long", "1", "1", 2, 10), position("3", "long", "1", "1", 10, 20)]
    result = replay(positions, "starting_cash" => "150", "trade_notional" => "100", "fee_bps" => "0", "slippage_bps" => "0")
    assert_equal 2, result["copied"]
    assert_equal({ "insufficient_cash" => 1 }, result["rejections"])
  end

  def test_exposure_cap_and_loss_floor
    positions = [position("1", "long", "1", "1", 1, 5), position("2", "long", "1", "1", 2, 5)]
    capped = replay(positions, "starting_cash" => "1000", "trade_notional" => "100", "max_exposure" => "0.15")
    assert_equal({ "exposure_cap" => 1 }, capped["rejections"])
    wiped = replay([position("1", "short", "100", "300", 1, 2)], "fee_bps" => "0", "slippage_bps" => "0")
    assert_equal "-100.0", wiped["trades"].first["pnl"]
    assert_equal "900.0", wiped["equity"]
    assert_equal "0.1", wiped["max_drawdown"]
  end

  def test_validation
    assert_raises(ArgumentError) { replay([], "leverage" => "10") }
    assert_raises(ArgumentError) { replay([], "trade_notional" => "2000") }
    assert_raises(ArgumentError) { replay([], "max_exposure" => "2") }
    assert_raises(ArgumentError) { replay([], "fee_bps" => "-1") }
    assert_raises(ArgumentError) { replay([position("1", "flat", "1", "1", 1, 2)]) }
    assert_raises(ArgumentError) { replay([position("1", "long", "0", "1", 1, 2)]) }
    assert_raises(ArgumentError) { replay([{}] * 301) }
    assert_nil replay([])["win_rate"]
  end
end
