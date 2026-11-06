# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/zero_x_da/trading_lab/okx_lead_traders"

class OkxPositionsTest < Minitest::Test
  Lead = ZeroXDA::TradingLab::OkxLeadTraders
  CODE = "9A8534AB09862774"

  # Documented example row from public-subpositions-history, with overrides.
  def row(id, opened: "1697698048031", **overrides)
    { "ccy" => "USDT", "closeAvgPx" => "28385.9", "closeTime" => (opened.to_i + 1000).to_s, "instId" => "BTC-USDT-SWAP",
      "instType" => "SWAP", "lever" => "20", "margin" => "4.245285", "mgnMode" => "isolated", "openAvgPx" => "28301.9",
      "openTime" => opened, "pnl" => "0.252", "pnlRatio" => "0.05935997229868", "posSide" => "long", "subPos" => "3",
      "subPosId" => id.to_s, "uniqueCode" => CODE }.merge(overrides.transform_keys(&:to_s))
  end

  def client(pages)
    requests = []
    transport = lambda do |uri|
      requests << URI.decode_www_form(uri.query).to_h
      [200, JSON.generate("code" => "0", "msg" => "", "data" => pages.shift || [])]
    end
    [Lead.new(transport: transport, clock: -> { 0.0 }, sleeper: ->(_) {}, throttle: { lock: Mutex.new, last_request_at: nil }), requests]
  end

  def test_normalizes_and_sorts_oldest_first
    api, requests = client([[row(2, opened: "1697698049000"), row(1, posSide: "net", subPos: "-3", lever: "3E+1")]])
    positions = api.positions(CODE)
    assert_equal({ "instType" => "SWAP", "uniqueCode" => CODE, "limit" => "100" }, requests.first)
    assert_equal %w[1 2], positions.map { |position| position["sub_position_id"] }
    first = positions.first
    assert_equal ["short", "30.0", "28301.9", "28385.9"], first.values_at("side", "leverage", "open_price", "close_price")
    assert_equal "2023-10-19T06:47:28.031Z", first["opened_at"]
  end

  def test_pages_backwards_with_the_oldest_sub_position_id
    full = (101..200).map { |id| row(id, opened: (1_697_698_000_000 + id).to_s) }
    api, requests = client([full, [row(5)]])
    assert_equal 101, api.positions(CODE).size
    assert_equal "101", requests[1]["after"]
    _, single = client([[row(1)]]).tap { |a, _| a.positions(CODE, max_pages: 1) }
    assert_equal 1, single.size
  end

  def test_rejects_untrusted_rows_and_arguments
    api, = client([])
    assert_raises(ArgumentError) { api.positions("../x") }
    assert_raises(ArgumentError) { api.positions(CODE, max_pages: 4) }
    [{ uniqueCode: "BBBBBBBBBBBBBBBB" }, { posSide: "flat" }, { openAvgPx: "0" }, { instId: "BTC/USDT" },
     { closeTime: "1697698000000" }, { subPosId: "x1" }].each do |override|
      bad, = client([[row(1, **override)]])
      assert_raises(Lead::Error, override.inspect) { bad.positions(CODE) }
    end
    duplicate, = client([(1..100).map { |id| row(id) }, [row(1)]])
    assert_raises(Lead::Error) { duplicate.positions(CODE) }
  end
end
