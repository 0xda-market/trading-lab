# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../lib/zero_x_da/trading_lab/http_app"

# Runs against a real PostgreSQL named by TRADING_LAB_TEST_DATABASE_URL. It drops and rebuilds
# the trading_lab schema, so point it only at a disposable database.
class ResearchStoreTest < Minitest::Test
  Lab = ZeroXDA::TradingLab
  URL = ENV["TRADING_LAB_TEST_DATABASE_URL"].to_s
  EVENTS = [
    { "kind" => "signal", "source" => "s", "id" => "1", "symbol" => "BTCUSDT", "side" => "buy", "received_at" => "2026-01-01T00:00:00Z" },
    { "kind" => "tick", "symbol" => "BTCUSDT", "price" => "100", "received_at" => "2026-01-01T00:00:01Z" }
  ].freeze

  def setup
    # CI must never pass by skipping the only tests that touch the database.
    flunk "TRADING_LAB_TEST_DATABASE_URL is required in CI" if URL.empty? && ENV["CI"]
    skip "set TRADING_LAB_TEST_DATABASE_URL to a disposable database" if URL.empty?
    @store = Lab::ResearchStore.new(URL)
    @store.with { |db| db.exec("DROP SCHEMA IF EXISTS trading_lab CASCADE") }
    @store.migrate!
    @app = Lab::HTTPApp.new(token: "test-secret", store: @store)
  end

  def call(method, path, body: "", query: "", app: @app)
    status, _, output = app.call("REQUEST_METHOD" => method, "PATH_INFO" => path, "QUERY_STRING" => query,
                                 "HTTP_AUTHORIZATION" => "Bearer test-secret", "rack.input" => StringIO.new(body))
    [status, JSON.parse(output.join)]
  end

  def record(**overrides)
    result = { "equity" => "1010.5", "net_pnl" => "10.5", "max_drawdown" => "0.02", "trades" => [] }
    @store.record_run(**{ kind: "copy_replay", subject: "9A8534AB09862774", options: { "fee_bps" => "10" }, input: [1],
                          result: result, portfolio: { "equity" => "1010.5" } }.merge(overrides))
  end

  def test_migrations_apply_once_and_refuse_an_edited_file
    assert_empty @store.migrate!
    @store.with { |db| db.exec("ALTER TABLE trading_lab.schema_migrations DISABLE TRIGGER ALL; UPDATE trading_lab.schema_migrations SET checksum = 'x'") }
    assert_raises(Lab::ResearchStore::Unavailable) { @store.migrate! }
  end

  def test_records_and_reads_runs_newest_first
    first = record
    second = record(experiment: "delay-sweep", input: [2], result: { "equity" => "990", "net_pnl" => "-10" })
    record(kind: "paper_replay", subject: nil)
    assert_equal [second, first], @store.runs(kind: "copy_replay").map { |run| run["id"] }
    assert_equal [second], @store.runs(experiment: "delay-sweep").map { |run| run["id"] }
    assert_equal [first], @store.runs(subject: "9A8534AB09862774", before: second).map { |run| run["id"] }
    run = @store.run(first)
    assert_equal ["copy_replay", nil, "1010.5", "10.5", "0.02", { "fee_bps" => "10" }],
                 run.values_at("kind", "experiment", "equity", "net_pnl", "max_drawdown", "options")
    assert_equal [{ "equity" => "1010.5" }, []], [run["portfolio"], run.dig("result", "trades")]
    assert_equal Lab::ResearchStore.digest([1]), run["input_digest"]
    refute_equal run["input_digest"], @store.run(second)["input_digest"]
    assert_nil @store.run(second)["max_drawdown"]
    assert_nil @store.run(999)
  end

  def test_runs_are_append_only_and_arguments_are_checked
    id = record
    assert_raises(Lab::ResearchStore::Unavailable) { @store.with { |db| db.exec("UPDATE trading_lab.simulation_runs SET equity = 1") } }
    assert_raises(Lab::ResearchStore::Unavailable) { @store.with { |db| db.exec("DELETE FROM trading_lab.simulation_runs") } }
    assert_equal "1010.5", @store.run(id)["equity"]
    assert_raises(ArgumentError) { record(kind: "live_order") }
    assert_raises(ArgumentError) { record(experiment: "Bad Name") }
    assert_raises(ArgumentError) { @store.runs(limit: 101) }
    assert_raises(ArgumentError) { Lab::ResearchStore.new("mysql://x") }
    assert_nil Lab::ResearchStore.from_env({})
  end

  def test_recovers_from_a_dropped_connection
    record
    @store.with { |db| db.close }
    assert_equal 1, @store.runs.size
  end

  def test_replays_are_persisted_and_served_back
    status, body = call("POST", "/v1/paper/replays", body: JSON.generate(events: EVENTS, experiment: "smoke"))
    assert_equal 200, status
    id = body.fetch("run_id")
    status, listed = call("GET", "/v1/research/runs", query: "kind=paper_replay&experiment=smoke&limit=5")
    assert_equal [200, [id]], [status, listed.dig("data", "runs").map { |run| run["id"] }]
    status, run = call("GET", "/v1/research/runs/#{id}")
    assert_equal 200, status
    assert_equal body["data"], run.dig("data", "result")
    assert_equal body["data"].slice("ending_cash", "equity", "open_positions"), run.dig("data", "portfolio")
    assert_equal Lab::ResearchStore.digest(EVENTS), run.dig("data", "input_digest")
    assert_equal 404, call("GET", "/v1/research/runs/999").first
    assert_equal 404, call("GET", "/v1/research/runs/0").first
    ["limit=0", "kind=live", "color=red", "limit=1&limit=2", "experiment=Bad+Name"].each do |query|
      assert_equal 422, call("GET", "/v1/research/runs", query: query).first, query
    end
    assert_equal 422, call("POST", "/v1/paper/replays", body: JSON.generate(events: [], experiment: "Bad Name")).first
    status, _, = @app.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/v1/research/runs", "QUERY_STRING" => "", "rack.input" => StringIO.new(""))
    assert_equal 401, status
  end

  def test_service_keeps_simulating_when_the_store_is_absent_or_down
    plain = Lab::HTTPApp.new(token: "test-secret", store: nil)
    status, body = call("POST", "/v1/paper/replays", body: JSON.generate(events: EVENTS), app: plain)
    assert_equal [200, false], [status, body.key?("run_id")]
    assert_equal 503, call("GET", "/v1/research/runs", app: plain).first
    assert_equal 503, call("POST", "/v1/paper/replays", body: JSON.generate(events: EVENTS, experiment: "smoke"), app: plain).first

    down = Lab::HTTPApp.new(token: "test-secret", store: Lab::ResearchStore.new("postgres://lab:lab@127.0.0.1:1/none"))
    status, body = call("POST", "/v1/paper/replays", body: JSON.generate(events: EVENTS), app: down)
    assert_equal [200, true, nil], [status, body.key?("run_id"), body["run_id"]]
    assert_equal 503, call("POST", "/v1/paper/replays", body: JSON.generate(events: EVENTS, experiment: "smoke"), app: down).first
    assert_equal 503, call("GET", "/v1/research/runs/1", app: down).first
  end
end
