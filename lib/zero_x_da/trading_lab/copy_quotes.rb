# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require_relative "okx_candles"

module ZeroXDA
  module TradingLab
    # Finds the prices a follower could really have traded at after each of a leader's
    # position signals, and the price path while the copy was held.
    #
    # A signal exists at the leader's open or close time. The follower acts `delay_ms` later
    # and is filled at the open of the first completed one-minute bar that starts at or after
    # that moment, so no price from before the signal can leak into a fill. The path is the
    # high/low/close of every bar overlapping the holding interval, at the finest bar size
    # the request budget allows.
    class CopyQuotes
      FILL_BAR = "1m"
      FILL_MS = OkxCandles::BARS.fetch(FILL_BAR)
      # A quiet instrument may skip a minute; past this many bars the quote counts as missing.
      TOLERANCE_BARS = 5
      MAX_REQUESTS = 120
      MAX_MARKS = 300_000

      def initialize(candles: OkxCandles.new, max_requests: MAX_REQUESTS, max_marks: MAX_MARKS)
        @candles = candles
        @max_requests = max_requests
        @max_marks = max_marks
      end

      # Returns { "mark_bar" => bar or nil, "requests" => count, "quotes" => { index => quote } }.
      # A position without both fills has no entry in "quotes".
      def call(positions, delay_ms)
        targets = Hash.new { |hash, key| hash[key] = [] }
        wanted = positions.each_with_index.map do |position, index|
          instrument = position.fetch("instrument")
          pair = [fill_target(position.fetch("opened_at_ms"), delay_ms), fill_target(position.fetch("closed_at_ms"), delay_ms)]
          targets[instrument].concat(pair)
          [index, instrument, pair]
        end
        windows = targets.transform_values { |list| fill_windows(list.uniq.sort) }
        requests = windows.values.sum(&:size)
        over_budget! if requests > @max_requests
        minutes = windows.to_h { |instrument, list| [instrument, fetch(instrument, FILL_BAR, list)] }

        quotes = {}
        wanted.each do |index, instrument, (entry_target, exit_target)|
          entry = first_bar(minutes[instrument], entry_target)
          exit = first_bar(minutes[instrument], exit_target)
          next unless entry && exit
          quotes[index] = { "instrument" => instrument, "entry" => [entry["start_ms"], entry["open"]],
                            "exit" => [exit["start_ms"], exit["open"]], "path" => [] }
        end

        bar, spans, path_requests = path_plan(quotes, @max_requests - requests)
        if bar
          width = OkxCandles::BARS.fetch(bar)
          bars = spans.to_h { |instrument, list| [instrument, fetch(instrument, bar, list)] }
          quotes.each_value { |quote| quote["path"] = path(bars[quote["instrument"]], quote, width) }
        end
        { "mark_bar" => bar, "requests" => requests + path_requests, "quotes" => quotes }
      end

      private

      def over_budget!
        raise ArgumentError, "too many positions to quote in one replay; lower max_positions"
      end

      def fill_target(at_ms, delay_ms)
        ((at_ms + delay_ms + FILL_MS - 1) / FILL_MS) * FILL_MS
      end

      # One request reads PAGE consecutive minutes, so nearby fills share a window.
      def fill_windows(targets)
        reach = (OkxCandles::PAGE - TOLERANCE_BARS) * FILL_MS
        targets.each_with_object([]) do |target, windows|
          next if windows.any? && target <= windows.last[0] + reach
          windows << [target, target + (OkxCandles::PAGE - 1) * FILL_MS]
        end
      end

      def fetch(instrument, bar, spans)
        spans.each_with_object({}) do |(from_ms, to_ms), bars|
          @candles.range(instrument, bar, from_ms, to_ms).each { |row| bars[row["start_ms"]] = row }
        rescue OkxPublic::UnknownInstrument
          # Delisted since the leader traded it: its copies are reported as unquoted.
          break bars
        end
      end

      def first_bar(bars, target)
        TOLERANCE_BARS.times do |step|
          bar = bars[target + step * FILL_MS]
          return bar if bar
        end
        nil
      end

      # The finest bar whose path fits the remaining request budget and the mark budget.
      def path_plan(quotes, budget)
        held = quotes.values.select { |quote| quote["exit"][0] > quote["entry"][0] }
        return [nil, {}, 0] if held.empty?
        OkxCandles::BARS.each do |bar, width|
          marks = 0
          spans = Hash.new { |hash, key| hash[key] = [] }
          held.each do |quote|
            from, to = span(quote, width)
            marks += (to - from) / width + 1
            spans[quote["instrument"]] << [from, to]
          end
          spans.transform_values! { |list| merge(list, width) }
          requests = spans.values.flatten(1).sum { |from, to| OkxCandles.requests_for((to - from) / width + 1) }
          return [bar, spans, requests] if requests <= budget && marks <= @max_marks
        end
        over_budget!
      end

      # Starts of the first and last bar that overlap the holding interval [entry, exit).
      def span(quote, width)
        [(quote["entry"][0] / width) * width, ((quote["exit"][0] - 1) / width) * width]
      end

      def merge(spans, width)
        spans.sort.each_with_object([]) do |(from, to), merged|
          if merged.any? && from <= merged.last[1] + width
            merged.last[1] = to if to > merged.last[1]
          else
            merged << [from, to]
          end
        end
      end

      # [at_ms, high, low, close] per bar. A bar that starts before the entry is stamped at the
      # entry, and a bar that ends after the exit carries no close: that close did not exist yet
      # for the follower. Extremes of both edge bars are kept, which can only overstate risk.
      def path(bars, quote, width)
        entry_at = quote["entry"][0]
        exit_at = quote["exit"][0]
        return [] unless exit_at > entry_at
        from, to = span(quote, width)
        (from..to).step(width).filter_map do |start|
          bar = bars[start]
          next unless bar
          [[start, entry_at].max, bar["high"], bar["low"], start + width <= exit_at ? bar["close"] : nil]
        end
      end
    end
  end
end
