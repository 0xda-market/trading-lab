# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/zero_x_da/trading_lab/okx_candles"

class OkxCandlesTest < Minitest::Test
  Lab = ZeroXDA::TradingLab
  T0 = 1_761_999_600_000

  def row(start, open: "100", high: "101", low: "99", close: "100.5", confirm: "1")
    [start.to_s, open, high, low, close, "1", "1", "1", confirm]
  end

  def client(pages, code: "0")
    requests = []
    transport = lambda do |uri|
      requests << URI.decode_www_form(uri.query).to_h
      [200, JSON.generate("code" => code, "msg" => "", "data" => pages.shift || [])]
    end
    okx = Lab::OkxPublic.new(transport: transport, clock: -> { 0.0 }, sleeper: ->(_) {}, min_interval: 0,
                             throttle: { lock: Mutex.new, last_request_at: nil })
    [Lab::OkxCandles.new(okx: okx), requests]
  end

  def test_reads_one_window_oldest_first_and_skips_the_forming_bar
    api, requests = client([[row(T0 + 120_000, confirm: "0"), row(T0 + 60_000), row(T0)]])
    bars = api.range("BTC-USDT-SWAP", "1m", T0, T0 + 120_000)
    assert_equal [T0, T0 + 60_000], bars.map { |bar| bar["start_ms"] }
    assert_equal BigDecimal("99"), bars.first["low"]
    assert_equal({ "instId" => "BTC-USDT-SWAP", "bar" => "1m", "after" => (T0 + 120_001).to_s, "before" => (T0 - 1).to_s, "limit" => "100" },
                 requests.first)
  end

  def test_pages_backwards_until_the_window_is_covered
    newest = (100..199).map { |step| row(T0 + step * 60_000) }.reverse
    oldest = (0..99).map { |step| row(T0 + step * 60_000) }.reverse
    api, requests = client([newest, oldest])
    assert_equal 200, api.range("BTC-USDT-SWAP", "1m", T0, T0 + 199 * 60_000).size
    assert_equal (T0 + 100 * 60_000).to_s, requests[1]["after"]
    assert_equal 2, requests.size
  end

  def test_rejects_untrusted_rows_and_arguments
    api, = client([])
    assert_raises(ArgumentError) { api.range("BTC-USDT-SWAP", "2s", T0, T0) }
    assert_raises(ArgumentError) { api.range("BTC/USDT", "1m", T0, T0) }
    assert_raises(ArgumentError) { api.range("BTC-USDT-SWAP", "1m", T0, T0 - 1) }
    [row(T0 - 60_000), row(T0 + 1), row(T0, low: "0"), row(T0, high: "100.1"), row(T0, open: "x"), ["1"]].each do |bad|
      broken, = client([[bad]])
      assert_raises(Lab::OkxPublic::Error, bad.inspect) { broken.range("BTC-USDT-SWAP", "1m", T0, T0 + 60_000) }
    end
    unknown, = client([], code: "51001")
    assert_raises(Lab::OkxPublic::UnknownInstrument) { unknown.range("GONE-USDT-SWAP", "1m", T0, T0) }
  end
end
