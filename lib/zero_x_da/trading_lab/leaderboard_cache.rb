# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

module ZeroXDA
  module TradingLab
    # Small in-memory cache for leaderboard pages. OKX publishes a new snapshot
    # every 10 minutes and limits each IP to 5 requests per 2 seconds, so a
    # short TTL keeps Mini App traffic away from the upstream limit.
    class LeaderboardCache
      def initialize(ttl_seconds: 60, max_entries: 64, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @ttl = ttl_seconds
        @max = max_entries
        @clock = clock
        @entries = {}
        @lock = Mutex.new
      end

      # Only successful results are cached; errors propagate and are retried next time.
      def fetch(key)
        now = @clock.call
        @lock.synchronize do
          entry = @entries[key]
          return entry[:value] if entry && now - entry[:at] < @ttl
        end
        value = yield
        @lock.synchronize do
          @entries.delete(key)
          @entries.shift while @entries.size >= @max
          @entries[key] = { value: value, at: now }
        end
        value
      end
    end
  end
end
