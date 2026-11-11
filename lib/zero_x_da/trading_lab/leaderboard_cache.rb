# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

module ZeroXDA
  module TradingLab
    # Small in-memory cache for upstream results. OKX publishes a new leaderboard snapshot
    # every 10 minutes and limits each IP per endpoint, so a short TTL keeps Mini App traffic
    # away from the upstream limit.
    #
    # Concurrent misses on one key compute once: the others wait for that result instead of
    # each repeating it. A cold quoted copy replay reads up to 120 candle pages, and two
    # identical requests racing each other would otherwise both spend that budget.
    class LeaderboardCache
      def initialize(ttl_seconds: 60, max_entries: 64, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @ttl = ttl_seconds
        @max = max_entries
        @clock = clock
        @entries = {}
        @flights = {}
        @lock = Mutex.new
      end

      # Only successful results are cached; errors propagate to every waiter and the next
      # call computes again.
      def fetch(key)
        flight = nil
        leader = false
        @lock.synchronize do
          entry = @entries[key]
          return entry[:value] if entry && @clock.call - entry[:at] < @ttl
          flight = @flights[key]
          unless flight
            flight = @flights[key] = { lock: Mutex.new, done: ConditionVariable.new, finished: false }
            leader = true
          end
        end
        leader ? lead(key, flight) { yield } : follow(flight)
      end

      private

      def lead(key, flight)
        value = yield
        now = @clock.call
        @lock.synchronize do
          @entries.delete(key)
          @entries.shift while @entries.size >= @max
          @entries[key] = { value: value, at: now }
        end
        finish(flight, value: value)
        value
      rescue StandardError => error
        finish(flight, error: error)
        raise
      ensure
        @lock.synchronize { @flights.delete(key) if @flights[key].equal?(flight) }
      end

      def follow(flight)
        flight[:lock].synchronize { flight[:done].wait(flight[:lock]) until flight[:finished] }
        raise flight[:error] if flight[:error]
        flight[:value]
      end

      def finish(flight, value: nil, error: nil)
        flight[:lock].synchronize do
          flight[:value] = value
          flight[:error] = error
          flight[:finished] = true
          flight[:done].broadcast
        end
      end
    end
  end
end
