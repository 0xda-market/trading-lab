# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require_relative "telegram_preview"
require_relative "telegram_signal_store"
require_relative "signal_rating"

module ZeroXDA
  module TradingLab
    # Long-running, read-only watcher of public Telegram channels. Every cycle it rereads the
    # newest page of each channel, stores new posts and whatever changed in known ones, and
    # rates the calls whose horizon has passed.
    #
    # An edit is seen at the next poll, not when it happened, and only while the post is still
    # on the newest page (about 20 posts). Several edits between two polls collapse into one.
    class TelegramSignalCollector
      MIN_INTERVAL_SECONDS = 15
      MAX_CHANNELS = 20
      MAX_BACKFILL_PAGES = 50
      RETRYABLE = [TelegramPreview::Error, ResearchStore::Unavailable, OkxPublic::Error].freeze

      def initialize(channels:, signals:, preview: TelegramPreview.new, rating: nil, interval_seconds: 60, backfill_pages: 0,
                     clock: -> { Time.now.utc }, sleeper: ->(seconds) { sleep(seconds) }, stop: -> { false }, log: ->(line) { warn(line) })
        @channels = channels.map { |name| TelegramPreview.channel(name) }
        raise ArgumentError, "specify between 1 and #{MAX_CHANNELS} distinct channels" unless (1..MAX_CHANNELS).cover?(@channels.size) && @channels.uniq.size == @channels.size
        raise ArgumentError, "interval_seconds must be at least #{MIN_INTERVAL_SECONDS}" unless interval_seconds.is_a?(Integer) && interval_seconds >= MIN_INTERVAL_SECONDS
        raise ArgumentError, "backfill_pages must be 0..#{MAX_BACKFILL_PAGES}" unless backfill_pages.is_a?(Integer) && (0..MAX_BACKFILL_PAGES).cover?(backfill_pages)
        @signals = signals
        @preview = preview
        @rating = rating
        @interval = interval_seconds
        @backfill = backfill_pages
        @clock = clock
        @sleeper = sleeper
        @stop = stop
        @log = log
      end

      # Backfills once, then polls until stopped; `once` ends after the first cycle.
      def run(once: false)
        @channels.each { |channel| guarded(channel) { backfill(channel) } } if @backfill.positive?
        until @stop.call
          cycle
          break if once || @stop.call
          @sleeper.call(@interval)
        end
      end

      # One pass over every channel. A channel that fails does not stop the others.
      def cycle
        @channels.each do |channel|
          guarded(channel) do
            counts = @signals.record_page(channel, @preview.page(channel), @clock.call)
            @log.call("telegram collector: #{channel} #{counts.map { |name, count| "#{name}=#{count}" }.join(' ')}") if counts.values.any?(&:positive?)
          end
        end
        guarded("rating") do
          rated = @rating ? @rating.evaluate_pending : 0
          @log.call("telegram collector: rated #{rated} calls") if rated.positive?
        end
      end

      private

      # Older history, read once. Posts found this way were not seen when they were new, so
      # they are kept as evidence but never rated.
      def backfill(channel)
        before = nil
        @backfill.times do
          page = @preview.page(channel, before: before)
          break if page.empty?
          @signals.record_page(channel, page, @clock.call, backfill: true)
          before = page.first["message_id"]
          break if before <= 1
        end
      end

      def guarded(subject)
        yield
      rescue *RETRYABLE => error
        @log.call("telegram collector: #{subject}: #{error.message}")
      end
    end
  end
end
