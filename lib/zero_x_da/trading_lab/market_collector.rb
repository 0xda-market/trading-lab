# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "json"
require_relative "okx_tickers"
require_relative "web_socket_client"
require_relative "research_store"

module ZeroXDA
  module TradingLab
    # Long-running, read-only recorder of OKX ticker quotes.
    #
    # It keeps one WebSocket subscription alive, reconnects with backoff, and hands every kept
    # tick to its sinks in collection order. It never backfills: what was not observed live is
    # a gap, and each connection is a session so that gaps stay visible.
    class MarketCollector
      # OKX drops a connection that is silent for 30 s; "ping" must be answered by "pong".
      IDLE_PING_SECONDS = 20
      PONG_TIMEOUT_SECONDS = 10
      MAX_BACKOFF_SECONDS = 30
      RETRYABLE = [WebSocketClient::Error, OkxTickers::Invalid, ResearchStore::Unavailable].freeze

      class ClockError < StandardError; end

      def initialize(sinks:, instruments: OkxTickers::DEFAULT_INSTRUMENTS, min_interval_ms: 1000, max_events: nil,
                     connect: -> { WebSocketClient.new(OkxTickers::URL).connect }, clock: -> { Time.now.utc },
                     sleeper: ->(seconds) { sleep(seconds) }, stop: -> { false }, log: ->(line) { warn(line) })
        @instruments = OkxTickers.instruments(instruments)
        raise ArgumentError, "at least one sink is required" if sinks.empty?
        raise ArgumentError, "min_interval_ms must be 0..60000" unless min_interval_ms.is_a?(Integer) && (0..60_000).cover?(min_interval_ms)
        raise ArgumentError, "max_events must be positive" unless max_events.nil? || (max_events.is_a?(Integer) && max_events.positive?)
        @sinks = sinks
        @interval = Rational(min_interval_ms, 1000)
        @max_events = max_events
        @connect = connect
        @clock = clock
        @sleeper = sleeper
        @stop = stop
        @log = log
        @count = 0
        @previous = nil
        @kept_at = {}
      end

      # Runs until stopped or until max_events ticks were kept; returns the number kept.
      def run
        backoff = 1
        until done?
          before = @count
          session
          break if done?
          backoff = @count > before ? 1 : [backoff * 2, MAX_BACKOFF_SECONDS].min
          @log.call("market collector: reconnecting in #{backoff} s; the interval in between is a gap")
          @sleeper.call(backoff)
        end
        @count
      end

      private

      def done?
        @stop.call || (@max_events && @count >= @max_events)
      end

      def session
        reason = "stopped"
        socket = @connect.call
        socket.send_text(OkxTickers.subscription(@instruments))
        @sinks.each { |sink| sink.open_session(OkxTickers::SOURCE, @instruments, now) }
        @log.call("market collector: connected, read-only #{OkxTickers::SOURCE} for #{@instruments.join(', ')}")
        idle = 0
        until done?
          message = socket.read(1)
          @sinks.each(&:flush)
          if message.nil?
            idle += 1
            socket.send_text("ping") if idle == IDLE_PING_SECONDS
            raise WebSocketClient::Error, "no pong from OKX" if idle >= IDLE_PING_SECONDS + PONG_TIMEOUT_SECONDS
            next
          end
          idle = 0
          next if message == "pong"
          keep(OkxTickers.ticks(message, received_at: now, instruments: @instruments))
        end
      rescue *RETRYABLE => error
        reason = error.message
        @log.call("market collector: #{error.message}")
      rescue StandardError => error
        reason = "fatal: #{error.class}"
        raise
      ensure
        socket&.close
        close_sinks(reason)
      end

      # At most one tick per instrument per interval: the channel can push ten a second, and
      # the kept one is always the first seen, never a later one stamped earlier.
      def keep(ticks)
        ticks.each do |tick|
          at = Time.iso8601(tick["received_at"])
          last = @kept_at[tick["instrument"]]
          next if last && at - last < @interval
          @kept_at[tick["instrument"]] = at
          @sinks.each { |sink| sink.write(tick) }
          @count += 1
          break if @max_events && @count >= @max_events
        end
      end

      # A clock that steps backwards would reorder ticks against collection order.
      def now
        at = @clock.call
        raise ClockError, "collector clock moved backwards" if @previous && at < @previous
        @previous = at
      end

      def close_sinks(reason)
        at = @previous || @clock.call
        @sinks.each do |sink|
          sink.close_session(at, reason)
        rescue ResearchStore::Unavailable => error
          @log.call("market collector: session not closed: #{error.message}")
        end
      end

      # Append-only JSONL in the paper replay's tick format. Sessions are not recorded here.
      class JsonlSink
        def initialize(path)
          @file = File.open(path, "a")
          @file.sync = true
        end

        def open_session(_source, _instruments, _at); end

        def write(tick)
          @file.write("#{JSON.generate(tick)}\n")
        end

        def flush; end

        def close_session(_at, _reason); end
      end

      # Buffers ticks and writes them to the research store about once a second. If the
      # database stays away the buffer is kept up to MAX_BUFFER ticks; past that the collector
      # stops instead of silently dropping what it observed.
      class StoreSink
        BATCH = 200
        MAX_BUFFER = 20_000

        class Overflow < StandardError; end

        def initialize(ticks, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, log: ->(line) { warn(line) })
          @ticks = ticks
          @clock = clock
          @log = log
          @buffer = []
          @session = nil
          @flushed_at = clock.call
        end

        # Ticks left over from a session the database could not take are written under that
        # session before a new one starts, so no tick is ever filed under the wrong connection.
        def open_session(source, instruments, at)
          drain if @session
          @session = @ticks.open_session(source, instruments, at)
        end

        def write(tick)
          @buffer << tick
          flush(force: @buffer.size >= BATCH)
        end

        def flush(force: false)
          return if @buffer.empty? || @session.nil?
          return unless force || @clock.call - @flushed_at >= 1
          @flushed_at = @clock.call
          drain
        rescue ResearchStore::Unavailable => error
          raise Overflow, "research store is down and #{@buffer.size} ticks are waiting" if @buffer.size >= MAX_BUFFER
          @log.call("market collector: #{error.message}; #{@buffer.size} ticks buffered")
        end

        def close_session(at, reason)
          return unless @session
          flush(force: true)
          # Ticks still buffered belong to this session; keep it to write them after a reconnect.
          return unless @buffer.empty?
          @ticks.close_session(@session, at, reason)
          @session = nil
        end

        private

        # A batch leaves the buffer only after the database accepted it.
        def drain
          until @buffer.empty?
            batch = @buffer.first(BATCH)
            @ticks.insert(@session, batch)
            @buffer.shift(batch.size)
          end
        end
      end
    end
  end
end
