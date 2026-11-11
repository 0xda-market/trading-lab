# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "bigdecimal"

module ZeroXDA
  module TradingLab
    # Deterministic reader of trade calls in channel posts. It turns "#BTC/USDT LONG, entry
    # 64000-64500, SL 63000, TP 66000" into a signal candidate and returns nil for anything
    # it cannot read unambiguously: a market opinion is not an order, and a call whose levels
    # contradict its direction is not counted as one.
    #
    # Bump VERSION whenever a rule changes; stored signals keep the version that read them.
    module SignalParser
      VERSION = 1
      NUMBER = /[1-9]\d{0,2}(?:,\d{3})+(?:\.\d+)?|\d+(?:[.,]\d+)?/
      PRICE = /(#{NUMBER.source})\s*(k\b)?/i
      # A ticker counts only when marked as one: "#BTC", "$BTC", "BTCUSDT", "BTC/USDT", "BTC-PERP".
      TICKER = %r{(?<![A-Za-z0-9])(?:[#$]([A-Z][A-Z0-9]{1,9})(?:\s*[/_-]?\s*(?:USDT|USD|PERP))?(?![A-Za-z0-9])|([A-Z][A-Z0-9]{1,9}?)\s*[/_-]?\s*(?:USDT|PERP)(?![A-Za-z0-9]))}
      QUOTES = %w[USDT USD USDC PERP].freeze
      LONG = /(?<![A-Za-z])(?:long|buy)(?![A-Za-z])|лонг|покуп/i
      SHORT = /(?<![A-Za-z])(?:short|sell)(?![A-Za-z])|шорт|продаж/i
      ENTRY = /(?<![A-Za-z])(?:entry|entries|enter|buy\s+zone|sell\s+zone|entry\s+zone)(?![A-Za-z])|вх[оі]д/i
      STOP = /(?<![A-Za-z])(?:stop[\s-]*loss|stoploss|sl|stop)(?![A-Za-z])|стоп/i
      # "TP1:", "Target 2 -" carry an index; "tp 0,11" and "tp 200" carry a price.
      TARGET = /(?<![A-Za-z])(?:take[\s-]*profits?|targets?|tp)(?![A-Za-z])(?:\s*\d{1,2}(?=\s*[:)\]=-]|\s+\d))?|тейк|ц[еі]л[ьиі]/i

      module_function

      def parse(text)
        return nil unless text.is_a?(String) && !text.empty?
        base = text.scan(TICKER).map(&:compact).flatten.reject { |name| QUOTES.include?(name) }.uniq
        long = LONG.match?(text)
        short = SHORT.match?(text)
        # Two instruments or both directions in one post cannot be turned into one call.
        return nil unless base.size == 1 && (long ^ short)
        entries = []
        stops = []
        targets = []
        text.each_line do |line|
          # "TP1: 66000 | SL 63000" on one line: each keyword owns the text up to the next one.
          marks = [[ENTRY, entries], [STOP, stops], [TARGET, targets]].flat_map do |pattern, bucket|
            line.to_enum(:scan, pattern).map { [Regexp.last_match.begin(0), Regexp.last_match.end(0), bucket] }
          end.sort_by(&:first)
          marks.each_with_index do |(_, finish, bucket), index|
            segment = line[finish...(marks[index + 1]&.first || line.size)]
            bucket.concat(prices(segment))
          end
        end
        signal = { "instrument" => "#{base.first}-USDT-SWAP", "side" => long ? "long" : "short",
                   "entry_low" => entries.min, "entry_high" => entries.max, "stop" => stops.first,
                   "targets" => targets.uniq.sort, "parser_version" => VERSION }
        signal["targets"].reverse! unless long
        return nil if entries.size > 2 || stops.uniq.size > 1 || !coherent?(signal, long)
        signal.transform_values { |value| format(value) }
      end

      # Stop on the losing side of the entry and every target on the winning side.
      def coherent?(signal, long)
        low, high, stop, targets = signal.values_at("entry_low", "entry_high", "stop", "targets")
        reference = long ? [high, targets.min].compact.min : [low, targets.max].compact.max
        return false if stop && reference && (long ? stop >= reference : stop <= reference)
        return true unless low
        targets.all? { |target| long ? target > low : target < high }
      end

      def prices(segment)
        segment.scan(PRICE).filter_map do |digits, thousand|
          # "65,000" and "1,250,000.5" group thousands; "0,095" and "1,5" are decimal commas.
          plain = digits.match?(/\A[1-9]\d{0,2}(?:,\d{3})+(?:\.\d+)?\z/) ? digits.delete(",") : digits.tr(",", ".")
          value = BigDecimal(plain) * (thousand ? 1000 : 1)
          value if value.positive?
        end
      end

      def format(value)
        case value
        when BigDecimal then value.to_s("F")
        when Array then value.map { |item| item.to_s("F") }
        else value
        end
      end
    end
  end
end
