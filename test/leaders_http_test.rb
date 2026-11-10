# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../lib/zero_x_da/trading_lab/http_app"
require_relative "support/fake_candles"

class LeadersHTTPTest < Minitest::Test
  Lead = ZeroXDA::TradingLab::OkxLeadTraders
  FIXTURE = File.read(File.expand_path("fixtures/okx_public_lead_traders.json", __dir__))

  def setup
    @requests = []
    @now = 0.0
    @upstream = [200, FIXTURE]
    transport = lambda do |uri|
      @requests << uri
      @upstream.is_a?(Proc) ? @upstream.call : @upstream
    end
    leaders = Lead.new(transport: transport, clock: -> { 0.0 }, sleeper: ->(_) {}, throttle: { lock: Mutex.new, last_request_at: nil })
    cache = ZeroXDA::TradingLab::LeaderboardCache.new(ttl_seconds: 60, max_entries: 2, clock: -> { @now })
    @app = ZeroXDA::TradingLab::HTTPApp.new(token: "test-secret", leaders: leaders, leaders_cache: cache)
  end

  def get(query = "", token: "test-secret", method: "GET")
    status, headers, body = @app.call("REQUEST_METHOD" => method, "PATH_INFO" => "/v1/leaders/okx", "QUERY_STRING" => query,
                                      "HTTP_AUTHORIZATION" => "Bearer #{token}", "rack.input" => StringIO.new(""))
    [status, headers, JSON.parse(body.join)]
  end

  def test_returns_normalized_leaderboard
    status, headers, body = get("sort=pnl_ratio&min_lead_days=90&limit=20")
    assert_equal 200, status
    assert_equal "no-store", headers["cache-control"]
    assert_equal "ok", body["status"]
    assert_equal "540D011FDACCB47A", body.dig("data", "traders", 0, "unique_code")
    assert_equal({ "instType" => "SWAP", "sortType" => "pnl_ratio", "minLeadDays" => "3", "limit" => "20" },
                 URI.decode_www_form(@requests.fetch(0).query).to_h)
  end

  def test_requires_service_token_before_upstream
    assert_equal 401, get(token: "wrong").first
    assert_empty @requests
  end

  def test_rejects_other_methods
    assert_equal 404, get(method: "POST").first
  end

  def test_invalid_options_are_422_without_upstream
    ["sort=luck", "limit=50", "api_key=x", "min_aum=10.5", "limit=1&limit=2"].each do |query|
      assert_equal 422, get(query).first, query
    end
    assert_empty @requests
    assert_equal 414, get("sort=#{'a' * 600}").first
  end

  def test_caches_by_normalized_query_until_ttl
    get("limit=5&sort=pnl")
    get("sort=pnl&limit=5")
    assert_equal 1, @requests.size
    get("sort=aum")
    assert_equal 2, @requests.size
    @now = 61.0
    get("sort=pnl&limit=5")
    assert_equal 3, @requests.size
  end

  def test_upstream_failures_are_not_cached
    @upstream = [429, ""]
    status, _, body = get
    assert_equal [503, "upstream_rate_limited"], [status, body["error"]]
    @upstream = [500, "oops"]
    assert_equal [502, "upstream_unavailable"], get.then { |s, _, b| [s, b["error"]] }
    @upstream = [200, FIXTURE]
    assert_equal 200, get.first
    assert_equal 3, @requests.size
  end

  def test_cache_is_bounded
    cache = ZeroXDA::TradingLab::LeaderboardCache.new(max_entries: 2, clock: -> { 0.0 })
    calls = 0
    %w[a b c a].each { |key| cache.fetch(key) { calls += 1 } }
    assert_equal 4, calls
  end
end

class CopyReplayHTTPTest < Minitest::Test
  POSITION = { "ccy" => "USDT", "closeAvgPx" => "110", "closeTime" => "1697698049031", "instId" => "BTC-USDT-SWAP",
               "instType" => "SWAP", "lever" => "20", "margin" => "1", "mgnMode" => "isolated", "openAvgPx" => "100",
               "openTime" => "1697698048031", "pnl" => "1", "pnlRatio" => "0.1", "posSide" => "long", "subPos" => "3",
               "subPosId" => "635126416883355648", "uniqueCode" => "9A8534AB09862774" }.freeze

  def setup
    @requests = []
    transport = ->(uri) { @requests << uri; [200, JSON.generate("code" => "0", "msg" => "", "data" => [POSITION])] }
    leaders = ZeroXDA::TradingLab::OkxLeadTraders.new(transport: transport, clock: -> { 0.0 }, sleeper: ->(_) {}, throttle: { lock: Mutex.new, last_request_at: nil })
    # The leader opens at 100 inside minute :47; the follower's first quote is the :48 open.
    @candles = FakeCandles.new(1_697_698_020_000 => "100", 1_697_698_080_000 => "105", 1_697_698_140_000 => "110")
    @app = ZeroXDA::TradingLab::HTTPApp.new(token: "test-secret", leaders: leaders,
                                            quotes: ZeroXDA::TradingLab::CopyQuotes.new(candles: @candles))
  end

  def post(body, token: "test-secret")
    status, _, output = @app.call("REQUEST_METHOD" => "POST", "PATH_INFO" => "/v1/paper/copy-replays",
                                  "HTTP_AUTHORIZATION" => "Bearer #{token}", "rack.input" => StringIO.new(body))
    [status, JSON.parse(output.join)]
  end

  def test_copies_the_real_positions_of_one_lead_trader
    status, body = post(JSON.generate(unique_code: "9A8534AB09862774", options: { fee_bps: "0", slippage_bps: "0", pricing: "leader" }))
    assert_equal 200, status
    assert_equal ["9A8534AB09862774", 1, "1010.0"], body["data"].values_at("unique_code", "copied", "equity")
    assert_match %r{public-subpositions-history}, @requests.first.path
    post(JSON.generate(unique_code: "9A8534AB09862774", options: { pricing: "leader" }))
    assert_equal 1, @requests.size, "positions are cached per trader"
  end

  def test_default_pricing_fills_at_quotes_after_the_follower_delay
    body = JSON.generate(unique_code: "9A8534AB09862774", options: { fee_bps: "0", slippage_bps: "0" })
    status, reply = post(body)
    assert_equal 200, status
    data = reply["data"]
    # The leader's 1 s trade (+10 %) is over before the follower's first quote: in and out at 105.
    assert_equal ["quotes", 5, 1, 1], data.values_at("pricing", "follower_delay_seconds", "copied", "positions_available")
    assert_equal %w[105.0 105.0 100.0 110.0], data["trades"].first.values_at("entry", "exit", "leader_entry", "leader_exit")
    assert_equal %w[1000.0 10.0 10.0], data.values_at("equity", "baseline_pnl", "delay_drag")
    calls = @candles.calls.size
    post(body)
    assert_equal calls, @candles.calls.size, "a finished copy replay is cached"
  end

  def test_rejects_bad_requests_before_okx
    assert_equal 401, post("{}", token: "wrong").first
    assert_equal 422, post(JSON.generate(unique_code: "../x")).first
    assert_equal 422, post(JSON.generate(unique_code: "9A8534AB09862774", options: { leverage: "50" })).first
    assert_equal 422, post(JSON.generate(code: "9A8534AB09862774")).first
    assert_equal 422, post(JSON.generate(unique_code: "9A8534AB09862774", options: { follower_delay_seconds: -1 })).first
    assert_empty @requests
  end
end
