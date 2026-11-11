# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../lib/zero_x_da/trading_lab/telegram_signal_collector"
require_relative "../lib/zero_x_da/trading_lab/http_app"
require_relative "support/fake_candles"

class TelegramSignalsTest < Minitest::Test
  Lab = ZeroXDA::TradingLab
  Parser = Lab::SignalParser
  FIXTURE = File.read(File.expand_path("fixtures/telegram_preview.html", __dir__))
  URL = ENV["TRADING_LAB_TEST_DATABASE_URL"].to_s
  T0 = Time.utc(2026, 11, 10, 12, 0, 0)
  M = 60_000
  T0_MS = T0.to_i * 1000

  def preview(status = 200, body = FIXTURE)
    requests = []
    slept = []
    reader = Lab::TelegramPreview.new(transport: ->(uri) { requests << uri.to_s; [status, body] }, clock: -> { 0.0 }, sleeper: ->(seconds) { slept << seconds })
    [reader, requests, slept]
  end

  def test_reads_posts_text_and_edit_marks_from_the_public_preview
    reader, requests, slept = preview
    posts = reader.page("@Alpha_Calls")
    assert_equal [101, 102, 104], posts.map { |post| post["message_id"] }, "a post of another channel is not this channel's"
    assert_equal "#BTC/USDT LONG\nEntry: 64,000 - 64,500\nSL: 63000\nTP1: 66000 & TP2: 68000 🚀", posts[0]["text"]
    assert_equal ["2026-11-10T12:00:00.000Z", false], posts[0].values_at("published_at", "edited")
    assert_equal ["Market looks heavy today, be careful.", true], posts[1].values_at("text", "edited"), "the quoted reply is not the post's text"
    assert_equal "", posts[2]["text"], "a media-only post has no text"
    reader.page("alpha_calls", before: 101)
    assert_equal ["https://t.me/s/alpha_calls", "https://t.me/s/alpha_calls?before=101"], requests
    assert_equal [1.0], slept, "requests to Telegram are spaced out"
  end

  def test_reports_channels_without_a_preview_and_bad_input
    assert_raises(Lab::TelegramPreview::NoPreview) { preview(302, "").first.page("alpha_calls") }
    assert_raises(Lab::TelegramPreview::NoPreview) { preview(200, "<html><body>nothing</body></html>").first.page("alpha_calls") }
    assert_raises(Lab::TelegramPreview::Error) { preview(500, "").first.page("alpha_calls") }
    assert_raises(Lab::TelegramPreview::Error) { preview(200, FIXTURE.sub("2026-11-10T12:00:00+00:00", "soon")).first.page("alpha_calls") }
    ["ab", "1abc", "has space", "../etc", "a" * 33].each { |name| assert_raises(ArgumentError, name) { preview.first.page(name) } }
    assert_raises(ArgumentError) { preview.first.page("alpha_calls", before: 0) }
  end

  def test_parser_reads_unambiguous_calls
    call = Parser.parse("#BTC/USDT LONG\nEntry: 64,000 - 64,500\nSL: 63000\nTP1: 66000\nTP2: 68k")
    assert_equal({ "instrument" => "BTC-USDT-SWAP", "side" => "long", "entry_low" => "64000.0", "entry_high" => "64500.0", "stop" => "63000.0",
                   "targets" => %w[66000.0 68000.0], "parser_version" => 1 }, call)
    short = Parser.parse("🔥 ETHUSDT SHORT 🔥\nEntry zone 2500-2520\nStop 2600\nTargets: 2450 - 2400 - 2300")
    assert_equal ["ETH-USDT-SWAP", "short", "2600.0", %w[2450.0 2400.0 2300.0]], short.values_at("instrument", "side", "stop", "targets"), "nearest target first"
    assert_equal ["SOL-USDT-SWAP", nil, "150.0", ["200.0"]], Parser.parse("$SOL buy now! tp 200 sl 150").values_at("instrument", "entry_low", "stop", "targets")
    assert_equal ["2500.0", "2550.0", ["2400.0"]], Parser.parse("Шорт #ETH вхід 2500 стоп 2550 тейк 2400").values_at("entry_low", "stop", "targets")
    assert_equal ["60000.0", ["70000.0"]], Parser.parse("LONG BTC-PERP TP1 70000 | SL 60000").values_at("stop", "targets")
    assert_equal ["0.095", ["0.11"]], Parser.parse("BUY #DOGE entry 0,095 tp 0,11 sl 0,09").values_at("entry_low", "targets")
  end

  def test_parser_refuses_opinions_and_contradictions
    ["BTC looks strong today, I think we go up", "#BTC long or short? vote", "#BTC and #ETH long",
     "#BTC LONG entry 64000 SL 65000 TP 66000", "#BTC SHORT entry 64000 TP 66000", "#BTC LONG SL 63000 SL 62000",
     "LONG the dip", "", "#USDT long"].each { |text| assert_nil Parser.parse(text), text }
    assert_nil Parser.parse(nil)
  end

  def store
    flunk "TRADING_LAB_TEST_DATABASE_URL is required in CI" if URL.empty? && ENV["CI"]
    skip "set TRADING_LAB_TEST_DATABASE_URL to a disposable database" if URL.empty?
    research = Lab::ResearchStore.new(URL)
    research.with { |db| db.exec("DROP SCHEMA IF EXISTS trading_lab CASCADE") }
    research.migrate!
    @research = research
    Lab::TelegramSignalStore.new(research)
  end

  def post(id, text, at: T0, edited: false)
    { "message_id" => id, "published_at" => at.iso8601(3), "text" => text, "edited" => edited }
  end

  LONG_CALL = "#BTC LONG entry 100 SL 95 TP 110"

  def test_keeps_every_revision_and_detects_edits_and_deletions
    signals = store
    first = signals.record_page("alpha_calls", [post(1, LONG_CALL), post(2, "gm"), post(3, "#ETH SHORT tp 2000")], T0 + 10)
    assert_equal({ "new" => 3, "edited" => 0, "deleted" => 0, "signals" => 2 }, first)
    assert_equal first.merge("new" => 0, "signals" => 0), signals.record_page("alpha_calls", [post(1, LONG_CALL), post(2, "gm"), post(3, "#ETH SHORT tp 2000")], T0 + 70)
    # After the market moved the channel raises its stop to hide a loss and removes the other call.
    changed = signals.record_page("alpha_calls", [post(1, "#BTC LONG entry 100 SL 80 TP 110", edited: true), post(3, "#ETH SHORT tp 2000")], T0 + 130)
    assert_equal({ "new" => 0, "edited" => 1, "deleted" => 1, "signals" => 1 }, changed)
    back = signals.record_page("alpha_calls", [post(1, "#BTC LONG entry 100 SL 80 TP 110", edited: true), post(2, "gm again"), post(3, "#ETH SHORT tp 2000")], T0 + 190)
    assert_equal [1, 0], back.values_at("edited", "deleted"), "a post that reappears is a new revision"

    newest, middle, oldest = signals.messages("alpha_calls")
    assert_equal [3, 2, 1], [newest, middle, oldest].map { |message| message["message_id"] }
    assert_equal %w[original edit], oldest["revisions"].map { |revision| revision["kind"] }
    assert_equal %w[95.0 80.0], oldest["revisions"].map { |revision| revision.dig("signal", "stop") }
    assert_equal [false, true], oldest["revisions"].map { |revision| revision["marked_edited"] }
    assert_equal ["2026-11-10T12:00:10.000000Z", "2026-11-10T12:02:10.000000Z"], oldest["revisions"].map { |revision| revision["observed_at"] }
    assert_equal [%w[original deleted edit], ["gm", "", "gm again"]], [middle["revisions"].map { |r| r["kind"] }, middle["revisions"].map { |r| r["text"] }]
    assert_nil middle["revisions"].first["signal"]
    assert_raises(Lab::ResearchStore::Unavailable) { @research.with { |db| db.exec("UPDATE trading_lab.telegram_message_revisions SET text = 'x'") } }
    assert_raises(Lab::ResearchStore::Unavailable) { @research.with { |db| db.exec("DELETE FROM trading_lab.telegram_signals") } }
  end

  def rating(signals, candles, now, **options)
    Lab::SignalRating.new(signals: signals, candles: candles, clock: -> { now }, horizon_hours: 1, delay_seconds: 5, **options)
  end

  def test_rates_calls_only_on_prices_after_they_were_seen
    signals = store
    signals.record_page("alpha_calls", [post(1, LONG_CALL)], T0 + 10)                                    # reaches the target
    signals.record_page("beta_calls", [post(1, "#BTC LONG entry 100 SL 95 TP 104")], T0 + 10)             # stop and target in one bar
    signals.record_page("beta_calls", [post(2, "#BTC SHORT entry 100 SL 130 TP 80", at: T0 + 60)], T0 + 70) # neither: expires
    signals.record_page("gamma_calls", [post(1, "#BTC LONG entry 90 SL 85 TP 100")], T0 + 10)              # target already passed
    signals.record_page("gamma_calls", [post(2, "#GONE LONG tp 5", at: T0 + 60)], T0 + 70)                 # delisted instrument
    signals.record_page("gamma_calls", [post(3, LONG_CALL, at: T0 - 86_400)], T0 + 10)                     # backfilled: seen a day late
    # Seen at 12:00:10, +5 s delay: the entry is the 12:01 open (100). 12:10 dips to 94 and spikes to 111.
    candles = FakeCandles.new({ T0_MS => "99", T0_MS + M => "100", T0_MS + 10 * M => "94", T0_MS + 11 * M => "111", T0_MS + 12 * M => "105" },
                              unknown: ["GONE-USDT-SWAP"])
    assert_equal 0, rating(signals, candles, T0 + 3600).evaluate_pending(limit: 10), "a call is not rated before its horizon is history"
    assert_equal 5, rating(signals, candles, T0 + 3600 + 300).evaluate_pending(limit: 10)
    assert_equal 0, rating(signals, candles, T0 + 7200).evaluate_pending(limit: 10), "an outcome is written once"

    alpha, beta, gamma = signals.ratings(max_lag_seconds: 300)
    # alpha: stop 95 > the 94 low, so the dip takes it out before the spike to its 110 target.
    assert_equal ["alpha_calls", 1, 0, 1, "0.0", "-0.05"], alpha.values_at("channel", "calls", "target", "stop", "accuracy", "average_return")
    assert_equal [2, 0, 1, 1, "0.0", 2], beta.values_at("calls", "target", "stop", "expired", "accuracy", "rated")
    assert_equal [3, 1, 1, 1, 0, nil, 1], gamma.values_at("calls", "missed", "no_quote", "late", "pending", "accuracy", "rated")
    expired = signals.messages("beta_calls").first["revisions"].first["signal"]
    assert_equal ["expired", "-0.05"], expired.values_at("outcome", "return"), "short from the 12:02 open at 100 to the 105 close"
  end

  # Bars that stop short of the horizon cannot prove an expiry, and an outcome is final.
  def test_a_call_whose_bars_end_early_is_unquoted_not_expired
    signals = store
    signals.record_page("alpha_calls", [post(1, LONG_CALL)], T0 + 10)
    halted = Class.new(FakeCandles) do
      def range(instrument, bar, from_ms, to_ms)
        super.select { |row| row["start_ms"] < from_ms + 20 * 60_000 }
      end
    end.new(T0_MS => "100")
    rating(signals, halted, T0 + 3600 + 300).evaluate_pending
    outcome = signals.messages("alpha_calls").first["revisions"].first.dig("signal", "outcome")
    assert_equal "no_quote", outcome
    assert_equal [0, 1, nil], signals.ratings(max_lag_seconds: 300).first.values_at("expired", "no_quote", "accuracy")
  end

  def test_a_winning_call_counts_and_a_later_edit_cannot_rewrite_it
    signals = store
    signals.record_page("alpha_calls", [post(1, "#BTC LONG entry 100 SL 90 TP 110")], T0 + 10)
    candles = FakeCandles.new(T0_MS => "100", T0_MS + 20 * M => "96", T0_MS + 30 * M => "112")
    # Two hours later the channel rewrites the call as if it had caught the whole move.
    signals.record_page("alpha_calls", [post(1, "#BTC LONG entry 96 SL 90 TP 112 ✅", edited: true)], T0 + 7200)
    rating(signals, candles, T0 + 7200 + 300).evaluate_pending
    alpha = signals.ratings(max_lag_seconds: 300).first
    assert_equal [1, 1, 0, "1.0", "0.1", 1, 0], alpha.values_at("calls", "target", "stop", "accuracy", "average_return", "edited_after", "deleted_after")
    original, edit = signals.messages("alpha_calls").first["revisions"]
    assert_equal ["target", nil], [original.dig("signal", "outcome"), edit.dig("signal", "outcome")], "only the call as first seen is rated"
    assert_raises(ArgumentError) { Lab::SignalRating.new(signals: signals, horizon_hours: 0) }
    assert_raises(ArgumentError) { signals.record_outcome(1, "outcome" => "won") }
  end

  def test_collector_polls_every_channel_survives_failures_and_serves_ratings
    signals = store
    pages = { "alpha_calls" => [[post(1, LONG_CALL)], [post(1, LONG_CALL), post(2, "gm", at: T0 + 60)]] }
    reader = Object.new
    reader.define_singleton_method(:page) do |channel, before: nil|
      raise Lab::TelegramPreview::NoPreview, "#{channel} has no public preview" unless pages.key?(channel)
      before ? [] : pages[channel].shift || []
    end
    now = T0
    log = []
    cycles = 0
    collector = Lab::TelegramSignalCollector.new(channels: %w[@Broken_Chan alpha_calls], signals: signals, preview: reader, backfill_pages: 2,
                                                 clock: -> { now += 10 }, sleeper: ->(_) { cycles += 1 }, stop: -> { cycles >= 1 }, log: ->(line) { log << line })
    collector.run
    assert_equal 1, cycles, "it sleeps between cycles until stopped"
    first, = signals.messages("alpha_calls").last(1)
    assert_equal [1, true], first.values_at("message_id", "backfilled"), "found by the backfill, though only seconds old"
    assert_equal [false], signals.messages("alpha_calls", limit: 1).map { |message| message["backfilled"] }
    assert_raises(Lab::ResearchStore::Unavailable) { @research.with { |db| db.exec("UPDATE trading_lab.telegram_messages SET backfilled = false") } }
    assert_includes log, "telegram collector: broken_chan: broken_chan has no public preview"
    assert_equal [2, 1], signals.messages("alpha_calls").map { |message| message["message_id"] }
    assert_raises(ArgumentError) { Lab::TelegramSignalCollector.new(channels: [], signals: signals) }
    assert_raises(ArgumentError) { Lab::TelegramSignalCollector.new(channels: %w[alpha_calls Alpha_Calls], signals: signals) }
    assert_raises(ArgumentError) { Lab::TelegramSignalCollector.new(channels: %w[alpha_calls], signals: signals, interval_seconds: 5) }

    app = Lab::HTTPApp.new(token: "test-secret", store: @research)
    get = lambda do |path, query = "", on = app|
      status, _, body = on.call("REQUEST_METHOD" => "GET", "PATH_INFO" => path, "QUERY_STRING" => query,
                                "HTTP_AUTHORIZATION" => "Bearer test-secret", "rack.input" => StringIO.new(""))
      [status, JSON.parse(body.join)]
    end
    status, body = get.call("/v1/signals/telegram/ratings")
    assert_equal [200, 300, [["alpha_calls", 2, 1, 0, 1]]],
                 [status, body.dig("data", "max_lag_seconds"), body.dig("data", "ratings").map { |row| row.values_at("channel", "messages", "calls", "pending", "late") }]
    status, body = get.call("/v1/signals/telegram/messages", "channel=%40Alpha_Calls&limit=1")
    assert_equal [200, [2]], [status, body.dig("data", "messages").map { |message| message["message_id"] }]
    assert_equal 422, get.call("/v1/signals/telegram/messages").first
    assert_equal 422, get.call("/v1/signals/telegram/messages", "channel=../x").first
    assert_equal 422, get.call("/v1/signals/telegram/ratings", "channel=alpha_calls").first
    assert_equal 503, get.call("/v1/signals/telegram/ratings", "", Lab::HTTPApp.new(token: "test-secret", store: nil)).first
  end
end
