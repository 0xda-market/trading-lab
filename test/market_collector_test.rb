# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "socket"
require "stringio"
require "tempfile"
require_relative "../lib/zero_x_da/trading_lab/market_collector"
require_relative "../lib/zero_x_da/trading_lab/market_tick_store"
require_relative "../lib/zero_x_da/trading_lab/http_app"

class MarketCollectorTest < Minitest::Test
  Lab = ZeroXDA::TradingLab
  Tickers = Lab::OkxTickers
  T0 = Time.utc(2026, 11, 10, 12, 0, 0)
  URL = ENV["TRADING_LAB_TEST_DATABASE_URL"].to_s

  def frame(instrument = "BTC-USDT", last: "74000.1", bid: "74000", ask: "74000.2", ts: "1794312000123")
    JSON.generate("arg" => { "channel" => "tickers", "instId" => instrument },
                  "data" => [{ "instType" => "SPOT", "instId" => instrument, "last" => last, "lastSz" => "0.1", "askPx" => ask,
                               "askSz" => "1.5", "bidPx" => bid, "bidSz" => "2", "ts" => ts }])
  end

  # Scripted socket: each entry is a message, nil (a silent second) or an error to raise.
  class Script
    attr_reader :sent, :closed

    def initialize(steps)
      @steps = steps
      @sent = []
    end

    def send_text(text)
      @sent << text
    end

    def read(_timeout)
      raise Lab::WebSocketClient::Error, "script ended" if @steps.empty?
      step = @steps.shift
      step.is_a?(Exception) ? raise(step) : step
    end

    def close
      @closed = true
    end
  end

  class Memory
    attr_reader :ticks, :sessions

    def initialize
      @ticks = []
      @sessions = []
    end

    def open_session(source, instruments, at)
      @sessions << [:open, source, instruments, at]
    end

    def write(tick)
      @ticks << tick
    end

    def flush; end

    def close_session(at, reason)
      @sessions << [:close, at, reason]
    end
  end

  def collector(scripts, sink: Memory.new, step: 0.5, **options)
    @now = T0
    @slept = []
    sockets = scripts.map { |steps| Script.new(steps) }
    queue = sockets.dup
    connect = -> { queue.shift || raise(Lab::WebSocketClient::Error, "no more scripts") }
    stop = -> { queue.empty? && sockets.last.instance_variable_get(:@steps).empty? }
    lab = Lab::MarketCollector.new(sinks: [sink], instruments: %w[BTC-USDT ETH-USDT], connect: connect, stop: stop,
                                   clock: -> { @now += step }, sleeper: ->(seconds) { @slept << seconds }, log: ->(_) {}, **options)
    [lab, sink, sockets]
  end

  def test_normalizes_a_ticker_frame_without_trusting_the_exchange_clock
    tick = Tickers.ticks(frame, received_at: T0, instruments: %w[BTC-USDT]).first
    assert_equal({ "kind" => "tick", "symbol" => "BTCUSDT", "price" => "74000.1", "received_at" => "2026-11-10T12:00:00.000000Z",
                   "source" => "okx.tickers", "instrument" => "BTC-USDT", "exchange_event_at" => "2026-11-10T12:00:00.123Z",
                   "bid" => "74000.0", "ask" => "74000.2", "bid_size" => "2.0", "ask_size" => "1.5" }, tick)
    assert_empty Tickers.ticks('{"event":"subscribe","arg":{"channel":"tickers","instId":"BTC-USDT"}}', received_at: T0, instruments: %w[BTC-USDT])
    assert_nil Tickers.ticks(frame(bid: "", ask: ""), received_at: T0, instruments: %w[BTC-USDT]).first["bid"]
    assert_equal '{"op":"subscribe","args":[{"channel":"tickers","instId":"BTC-USDT"}]}', Tickers.subscription(%w[BTC-USDT])
  end

  def test_rejects_untrusted_frames_and_instruments
    ["not json", "[]", '{"arg":{"channel":"trades"},"data":[]}', frame("DOGE-USDT"), frame(last: "0"), frame(last: "-1"),
     frame(bid: "2", ask: "1"), frame(ts: "soon")].each do |bad|
      assert_raises(Tickers::Invalid, bad) { Tickers.ticks(bad, received_at: T0, instruments: %w[BTC-USDT]) }
    end
    assert_raises(Tickers::Rejected) { Tickers.ticks('{"event":"error","code":"60018","msg":"no"}', received_at: T0, instruments: %w[BTC-USDT]) }
    assert_raises(ArgumentError) { Tickers.ticks(frame, received_at: Time.at(0), instruments: %w[BTC-USDT]) }
    [[], ["btc-usdt"], %w[BTC-USDT BTC-USDT], ["BTC-USDT"] * 11, ["BTC/USDT"]].each do |list|
      assert_raises(ArgumentError, list.inspect) { Tickers.instruments(list) }
    end
  end

  def test_keeps_one_tick_per_instrument_per_interval_in_collection_order
    lab, sink, sockets = collector([[frame, frame(last: "74001"), frame("ETH-USDT", last: "2500", bid: "2499", ask: "2501"), frame(last: "74002")]])
    assert_equal 3, lab.run
    # Clock ticks 0.5 s per read: the second BTC frame arrives inside the 1 s interval.
    assert_equal [%w[BTC-USDT 74000.1], %w[ETH-USDT 2500.0], %w[BTC-USDT 74002.0]], sink.ticks.map { |tick| tick.values_at("instrument", "price") }
    assert_equal sink.ticks.map { |tick| tick["received_at"] }.sort, sink.ticks.map { |tick| tick["received_at"] }
    assert_equal [Tickers.subscription(%w[BTC-USDT ETH-USDT])], sockets.first.sent
    assert_equal [:open, "okx.tickers", %w[BTC-USDT ETH-USDT]], sink.sessions.first.first(3)
    assert sockets.first.closed
  end

  def test_reconnects_with_backoff_and_records_each_connection_as_a_session
    lost = Lab::WebSocketClient::Error.new("connection lost: EOFError")
    lab, sink, = collector([[lost], [lost], [frame, lost], [frame(last: "74005")]], min_interval_ms: 0)
    assert_equal 2, lab.run
    assert_equal [2, 4, 1], @slept, "backoff doubles while nothing arrives and resets after a tick"
    assert_equal 4, sink.sessions.count { |entry| entry.first == :open }
    assert_equal ["connection lost: EOFError"] * 3, sink.sessions.select { |entry| entry.first == :close }.first(3).map(&:last)
  end

  def test_pings_a_silent_connection_and_gives_up_without_a_pong
    alive, _, sockets = collector([[nil] * 20 + ["pong", frame]], min_interval_ms: 0)
    assert_equal 1, alive.run
    assert_equal "ping", sockets.first.sent.last
    dead, sink, = collector([[nil] * 30, [frame]], min_interval_ms: 0)
    assert_equal 1, dead.run
    assert_equal "no pong from OKX", sink.sessions.find { |entry| entry.first == :close }.last
  end

  def test_stops_on_a_rejected_subscription_a_backwards_clock_and_max_events
    rejected, sink, = collector([['{"event":"error","code":"60018","msg":"no"}']])
    assert_raises(Tickers::Rejected) { rejected.run }
    assert_equal "fatal: ZeroXDA::TradingLab::OkxTickers::Rejected", sink.sessions.last.last
    backwards, = collector([[frame, frame]], step: -1)
    assert_raises(Lab::MarketCollector::ClockError) { backwards.run }
    capped, sink, = collector([[frame, frame, frame]], min_interval_ms: 0, max_events: 2)
    assert_equal [2, 2], [capped.run, sink.ticks.size]
    assert_raises(ArgumentError) { Lab::MarketCollector.new(sinks: []) }
    assert_raises(ArgumentError) { Lab::MarketCollector.new(sinks: [Memory.new], min_interval_ms: -1) }
  end

  def test_jsonl_sink_appends_replayable_ticks
    Tempfile.create("ticks") do |file|
      lab, = collector([[frame, frame("ETH-USDT", last: "2500", bid: "2499", ask: "2501")]], sink: Lab::MarketCollector::JsonlSink.new(file.path))
      lab.run
      lines = File.readlines(file.path).map { |line| JSON.parse(line) }
      assert_equal %w[BTCUSDT ETHUSDT], lines.map { |line| line["symbol"] }
      events = [lines.first, { "kind" => "signal", "source" => "t", "id" => "1", "symbol" => "ETHUSDT", "side" => "buy", "received_at" => lines.first["received_at"] }, lines.last]
      assert_equal 1, Lab::Replay.call(events)["fills"].size, "collected ticks feed the paper replay unchanged"
    end
  end

  # A real WebSocket handshake and frames against a local server.
  def test_web_socket_client_exchanges_text_with_a_real_server
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      peer = server.accept
      driver = WebSocket::Driver.server(peer)
      driver.on(:connect) { driver.start }
      driver.on(:message) { |event| driver.text(event.data == "ping" ? "pong" : "echo:#{event.data}") }
      loop { driver.parse(peer.readpartial(4096)) }
    rescue IOError, SystemCallError
      nil
    end
    port = server.addr[1]
    client = Lab::WebSocketClient.new("ws://127.0.0.1:#{port}/ws/v5/public").connect
    client.send_text("hello")
    assert_equal "echo:hello", client.read(5)
    client.send_text("ping")
    assert_equal "pong", client.read(5)
    assert_nil client.read(0.05)
    thread.kill
    server.close
    client.close
    refused = assert_raises(Lab::WebSocketClient::Error) { Lab::WebSocketClient.new("ws://127.0.0.1:#{port}/").connect }
    assert_match(/connection failed/, refused.message)
    assert_raises(ArgumentError) { Lab::WebSocketClient.new("https://example.com") }
  end

  def database
    flunk "TRADING_LAB_TEST_DATABASE_URL is required in CI" if URL.empty? && ENV["CI"]
    skip "set TRADING_LAB_TEST_DATABASE_URL to a disposable database" if URL.empty?
    store = Lab::ResearchStore.new(URL)
    store.with { |db| db.exec("DROP SCHEMA IF EXISTS trading_lab CASCADE") }
    store.migrate!
    store
  end

  def test_store_sink_persists_ticks_and_sessions_and_serves_coverage
    store = database
    ticks = Lab::MarketTickStore.new(store)
    lost = Lab::WebSocketClient::Error.new("connection lost: EOFError")
    lab, = collector([[frame, frame("ETH-USDT", last: "2500", bid: "", ask: ""), lost], [frame(last: "74009")]],
                     sink: Lab::MarketCollector::StoreSink.new(ticks, log: ->(_) {}), min_interval_ms: 0)
    assert_equal 3, lab.run
    newest, oldest = ticks.sessions
    assert_equal [2, "connection lost: EOFError", %w[BTC-USDT ETH-USDT], "okx.tickers"], oldest.values_at("ticks", "end_reason", "instruments", "source")
    assert_equal [1, "stopped"], newest.values_at("ticks", "end_reason")
    assert_operator newest["connected_at"], :>, oldest["ended_at"], "the reconnect leaves a visible gap"
    rows = ticks.ticks("BTC-USDT", from: T0, to: T0 + 60)
    assert_equal [%w[74000.1 74000.0 74000.2], %w[74009.0 74000.0 74000.2]], rows.map { |row| row.values_at("price", "bid", "ask") }
    assert_equal [oldest["id"], newest["id"]], rows.map { |row| row["session_id"] }
    assert_equal "2026-11-10T12:00:00.123000Z", rows.first["exchange_event_at"]
    assert_nil ticks.ticks("ETH-USDT", from: T0, to: T0 + 60).first["bid"]
    assert_raises(Lab::ResearchStore::Unavailable) { store.with { |db| db.exec("DELETE FROM trading_lab.market_ticks") } }

    app = Lab::HTTPApp.new(token: "test-secret", store: store)
    get = lambda do |query, on = app|
      status, _, body = on.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/v1/market/sessions", "QUERY_STRING" => query,
                                "HTTP_AUTHORIZATION" => "Bearer test-secret", "rack.input" => StringIO.new(""))
      [status, JSON.parse(body.join)]
    end
    status, body = get.call("limit=1")
    assert_equal [200, [newest["id"]]], [status, body.dig("data", "sessions").map { |session| session["id"] }]
    assert_equal 422, get.call("limit=0").first
    assert_equal 422, get.call("page=2").first
    assert_equal 503, get.call("", Lab::HTTPApp.new(token: "test-secret", store: nil)).first
  end

  def test_a_crashed_session_is_closed_at_its_last_tick_and_a_database_outage_loses_nothing
    store = database
    ticks = Lab::MarketTickStore.new(store)
    crashed = ticks.open_session("okx.tickers", %w[BTC-USDT], T0)
    ticks.insert(crashed, [Tickers.ticks(frame, received_at: T0 + 5, instruments: %w[BTC-USDT]).first])
    ticks.open_session("okx.tickers", %w[BTC-USDT], T0 + 60)
    assert_equal ["abandoned", "2026-11-10T12:00:05.000000Z"], ticks.sessions.last.values_at("end_reason", "ended_at")

    # The database goes away mid-session: ticks wait in the buffer and land under their own session.
    flaky = Class.new do
      attr_accessor :down

      def initialize(real)
        @real = real
      end

      def insert(*arguments)
        raise ZeroXDA::TradingLab::ResearchStore::Unavailable, "research store is unreachable" if down
        @real.insert(*arguments)
      end

      def open_session(*arguments) = @real.open_session(*arguments)
      def close_session(*arguments) = @real.close_session(*arguments)
    end.new(ticks)
    sink = Lab::MarketCollector::StoreSink.new(flaky, clock: -> { 0 }, log: ->(_) {})
    sink.open_session("okx.tickers", %w[BTC-USDT], T0 + 120)
    first = ticks.sessions.first["id"]
    flaky.down = true
    sink.write(Tickers.ticks(frame(last: "1"), received_at: T0 + 121, instruments: %w[BTC-USDT]).first)
    sink.flush(force: true)
    sink.close_session(T0 + 122, "connection lost")
    assert_nil ticks.sessions.first["ended_at"], "a session with unwritten ticks stays open"
    flaky.down = false
    sink.open_session("okx.tickers", %w[BTC-USDT], T0 + 130)
    assert_equal [first], ticks.ticks("BTC-USDT", from: T0 + 121, to: T0 + 121).map { |row| row["session_id"] }
    flaky.down = true
    overflow = Lab::MarketCollector::StoreSink::MAX_BUFFER
    tick = Tickers.ticks(frame, received_at: T0 + 131, instruments: %w[BTC-USDT]).first
    assert_raises(Lab::MarketCollector::StoreSink::Overflow) { (overflow + 1).times { sink.write(tick) } }
  end
end
