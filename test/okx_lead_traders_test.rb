# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/zero_x_da/trading_lab/okx_lead_traders"

class OkxLeadTradersTest < Minitest::Test
  FIXTURE = File.read(File.expand_path("fixtures/okx_public_lead_traders.json", __dir__))

  def client(status: 200, body: FIXTURE, requests: [], clock: -> { 0.0 }, sleeps: [])
    transport = lambda do |uri|
      requests << uri
      [status, body]
    end
    ZeroXDA::TradingLab::OkxLeadTraders.new(transport: transport, clock: clock, sleeper: ->(seconds) { sleeps << seconds },
                                            throttle: { lock: Mutex.new, last_request_at: nil })
  end

  def test_normalizes_documented_example
    result = client.ranks
    assert_equal "okx", result["source"]
    assert_equal "20231129213200", result["data_version"]
    assert_equal 1, result["page"]
    assert_equal 1, result["total_pages"]
    assert_equal 10, result["limit"]
    trader = result["traders"].fetch(0)
    assert_equal "540D011FDACCB47A", trader["unique_code"]
    assert_equal "Crypto to the moon", trader["nickname"]
    assert_equal "48805.1105999999972258", trader["pnl_90d"]
    assert_equal "1.6898", trader["pnl_ratio_90d"]
    assert_equal "0.6957", trader["win_ratio"]
    assert_equal 156, trader["lead_days"]
    assert_equal 999, trader["copy_traders"]
    assert_equal "0", trader["copy_state"]
    assert trader["has_capacity"]
    refute trader.key?("has_vacancy")
    assert_equal %w[ICP-USDT-SWAP MINA-USDT-SWAP], trader["instruments"]
    assert_equal [{ "begin_at" => "2023-11-28T16:00:00.000Z", "pnl_ratio" => "1.6744" },
                  { "begin_at" => "2023-11-23T16:00:00.000Z", "pnl_ratio" => "1.649" }], trader["daily_pnl_ratios"]
    refute trader.key?("portLink")
    refute trader.key?("portrait_link")
  end

  def test_maps_options_to_public_query_without_credentials
    requests = []
    client(requests: requests).ranks(sort: "pnl_ratio", state: "vacancy", min_lead_days: 90, min_aum: "1000", page: 2, limit: 20, data_version: "20231129213200")
    uri = requests.fetch(0)
    assert_equal "https", uri.scheme
    assert_equal "www.okx.com", uri.host
    assert_equal "/api/v5/copytrading/public-lead-traders", uri.path
    assert_equal({ "instType" => "SWAP", "sortType" => "pnl_ratio", "state" => "1", "minLeadDays" => "3", "minAum" => "1000",
                   "dataVer" => "20231129213200", "page" => "2", "limit" => "20" }, URI.decode_www_form(uri.query).to_h)
  end

  def test_rejects_invalid_options_before_any_request
    requests = []
    api = client(requests: requests)
    [{ "sort" => "luck" }, { "limit" => 21 }, { "limit" => 0 }, { "page" => 0 }, { "min_lead_days" => 14 },
     { "state" => "open" }, { "min_aum" => "-1" }, { "max_assets" => "Infinity" }, { "min_aum" => "10.5" }, { "min_assets" => "1e3" }, { "data_version" => "2023" },
     { "api_key" => "x" }].each do |options|
      assert_raises(ArgumentError, options.inspect) { api.ranks(options) }
    end
    assert_empty requests
  end

  def test_rate_limit_by_http_status_and_okx_code
    assert_raises(ZeroXDA::TradingLab::OkxLeadTraders::RateLimited) { client(status: 429, body: "").ranks }
    body = JSON.generate("code" => "50011", "msg" => "Rate limit reached", "data" => [])
    assert_raises(ZeroXDA::TradingLab::OkxLeadTraders::RateLimited) { client(body: body).ranks }
  end

  def test_upstream_errors
    error = ZeroXDA::TradingLab::OkxLeadTraders::Error
    assert_raises(error) { client(status: 503).ranks }
    assert_raises(error) { client(body: "<html>").ranks }
    assert_raises(error) { client(body: JSON.generate("code" => "51000", "msg" => "Parameter error", "data" => [])).ranks }
    document = JSON.parse(FIXTURE)
    document["data"][0]["ranks"][0]["pnl"] = "NaN"
    assert_raises(error) { client(body: JSON.generate(document)).ranks }
    document = JSON.parse(FIXTURE)
    document["data"][0]["ranks"][0]["uniqueCode"] = "../../x"
    assert_raises(error) { client(body: JSON.generate(document)).ranks }
  end

  def test_capacity_is_not_copy_eligibility
    trader = client.ranks["traders"][0]
    assert_equal "0", trader["copy_state"]
    assert trader["has_capacity"]
    refute trader.keys.any? { |key| key.match?(/eligib|vacancy|copyable/) }
  end

  def test_rejects_contradictory_bounds_before_request
    requests = []
    api = client(requests: requests)
    assert_raises(ArgumentError) { api.ranks(min_assets: "100", max_assets: "99.9") }
    assert_raises(ArgumentError) { api.ranks(min_aum: "5000", max_aum: "10") }
    assert_empty requests
    api.ranks(min_aum: "10", max_aum: "10")
    assert_equal 1, requests.size
  end

  def test_full_trader_has_no_capacity
    document = JSON.parse(FIXTURE)
    document["data"][0]["ranks"][0]["copyTraderNum"] = "1000"
    refute client(body: JSON.generate(document)).ranks["traders"][0]["has_capacity"]
  end

  def test_rejects_substituted_data_version
    error = assert_raises(ZeroXDA::TradingLab::OkxLeadTraders::Error) { client.ranks(data_version: "20231129212200") }
    assert_match(/no longer available/, error.message)
    assert_equal "20231129213200", client.ranks(data_version: "20231129213200")["data_version"]
  end

  def test_shared_throttle_across_instances
    sleeps = []
    shared = { lock: Mutex.new, last_request_at: nil }
    times = [5.0, 5.0]
    2.times do
      ZeroXDA::TradingLab::OkxLeadTraders.new(transport: ->(_) { [200, FIXTURE] }, clock: -> { times.shift },
                                              sleeper: ->(s) { sleeps << s }, throttle: shared).ranks
    end
    assert_equal [0.4], sleeps
  end

  def test_concurrent_calls_share_one_throttle
    shared = { lock: Mutex.new, last_request_at: nil }
    sleeps = Queue.new
    threads = 4.times.map do
      Thread.new do
        ZeroXDA::TradingLab::OkxLeadTraders.new(transport: ->(_) { [200, FIXTURE] }, clock: -> { 0.0 },
                                                sleeper: ->(s) { sleeps << s }, throttle: shared).ranks
      end
    end
    threads.each(&:join)
    waits = Array.new(sleeps.size) { sleeps.pop }.sort
    assert_equal [0.4, 0.8, 1.2], waits.map { |w| w.round(10) }
    assert_in_delta 1.2, shared[:last_request_at], 1e-9
  end

  def test_preserves_upstream_rank_order
    document = JSON.parse(FIXTURE)
    first = document["data"][0]["ranks"][0]
    document["data"][0]["ranks"] = [first.merge("uniqueCode" => "BBBBBBBBBBBBBBBB", "pnlRatio" => "0.1"),
                                    first.merge("uniqueCode" => "381749205163847291", "pnlRatio" => "9.9")]
    codes = client(body: JSON.generate(document)).ranks["traders"].map { |trader| trader["unique_code"] }
    assert_equal %w[BBBBBBBBBBBBBBBB 381749205163847291], codes
  end

  def test_throttles_to_documented_ip_limit
    times = [10.0, 10.1, 11.0]
    sleeps = []
    api = client(clock: -> { times.shift }, sleeps: sleeps)
    3.times { api.ranks }
    assert_equal 1, sleeps.size
    assert_in_delta 0.3, sleeps.first, 1e-9
  end
end
