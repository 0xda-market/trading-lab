# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "bigdecimal"
require "time"

module ZeroXDA
  module TradingLab
    # Paper simulation of copying a lead trader's real closed positions.
    #
    # Every leader position is copied with a fixed, unlevered USDT notional. With the default
    # "quotes" pricing the follower trades at the first market price observed after each of
    # the leader's signals plus the follower's own delay (see CopyQuotes), never at the
    # leader's fill, and open copies are marked to market on every bar in between, so the
    # drawdown covers the moves inside a trade and not only its outcome. "leader" pricing
    # keeps the optimistic model that fills at the leader's average prices, for comparison.
    #
    # Fills move against the follower by slippage and pay a fee on both sides. Opens, closes
    # and marks run in time order; a copy is rejected when free cash or the exposure cap
    # cannot cover it, and it is liquidated when its mark reaches zero, so it can lose at
    # most its notional. Nothing here places an order.
    class CopyReplay
      DEFAULTS = { "starting_cash" => "1000", "trade_notional" => "100", "fee_bps" => "10",
                   "slippage_bps" => "5", "max_exposure" => "1", "pricing" => "quotes",
                   "follower_delay_seconds" => 5, "max_positions" => 100 }.freeze
      PRICINGS = %w[quotes leader].freeze
      MAX_POSITIONS = 300
      MAX_DELAY_SECONDS = 3600
      MONEY = 8
      MODELS = {
        "quotes" => "fixed unlevered notional at the first quote after each leader signal plus the follower delay, " \
                    "adverse slippage, fee on both sides, marked to market on every bar",
        "leader" => "fixed unlevered notional at the leader's real average prices, adverse slippage, fee on both sides"
      }.freeze

      def self.call(positions, options = {}, quotes = nil)
        new(options).call(positions, quotes)
      end

      def initialize(options = {})
        raise ArgumentError, "options must be an object" unless options.is_a?(Hash)
        options = options.transform_keys(&:to_s)
        raise ArgumentError, "unknown option" unless (options.keys - DEFAULTS.keys).empty?
        settings = DEFAULTS.merge(options)
        @initial = decimal(settings["starting_cash"], "starting_cash")
        @notional = decimal(settings["trade_notional"], "trade_notional")
        @fee = decimal(settings["fee_bps"], "fee_bps", zero: true) / 10_000
        @slippage = decimal(settings["slippage_bps"], "slippage_bps", zero: true) / 10_000
        @max_exposure = decimal(settings["max_exposure"], "max_exposure")
        @pricing = settings["pricing"]
        @delay = integer(settings["follower_delay_seconds"], "follower_delay_seconds", 0..MAX_DELAY_SECONDS)
        @max_positions = integer(settings["max_positions"], "max_positions", 1..MAX_POSITIONS)
        raise ArgumentError, "pricing must be one of #{PRICINGS.join(', ')}" unless PRICINGS.include?(@pricing)
        raise ArgumentError, "fee_bps and slippage_bps must be below 10000" if @fee >= 1 || @slippage >= 1
        raise ArgumentError, "max_exposure must be at most 1" if @max_exposure > 1
        raise ArgumentError, "trade_notional must not exceed starting_cash" if @notional > @initial
      end

      def quoted?
        @pricing == "quotes"
      end

      def delay_ms
        @delay * 1000
      end

      # The most recent `max_positions` of a leader's positions, which arrive oldest first.
      def select(positions)
        raise ArgumentError, "positions must be an array" unless positions.is_a?(Array)
        positions.last(@max_positions)
      end

      def call(positions, quotes = nil)
        raise ArgumentError, "positions must be an array (maximum #{MAX_POSITIONS})" unless positions.is_a?(Array) && positions.size <= MAX_POSITIONS
        raise ArgumentError, "quotes pricing needs market quotes" if quoted? && !quotes.is_a?(Hash)
        rejections = Hash.new(0)
        events = []
        plans = positions.each_with_index.map do |position, index|
          raise ArgumentError, "position #{index + 1} must be an object" unless position.is_a?(Hash)
          plan = plan(position, quoted? ? quotes.fetch("quotes")[index] : nil)
          if plan
            events << [plan[:open_at], 1, index, :open] << [plan[:close_at], 0, index, :close]
            plan[:path].each { |at, high, low, close| events << [at, 2, index, :mark, plan[:long] ? low : high, close] }
          else
            rejections["no_quote"] += 1
          end
          plan
        end
        # Time order; at the same millisecond closes free cash before opens use it, and marks
        # see the book after both.
        events.sort_by! { |event| event.first(3) }

        @cash = @initial
        @exposure = BigDecimal("0")
        @marked = BigDecimal("0")
        @open = {}
        @trades = []
        @fees = BigDecimal("0")
        @baseline = BigDecimal("0")
        @unslipped = BigDecimal("0")
        peak = realized_peak = @initial
        max_drawdown = realized_drawdown = BigDecimal("0")

        events.chunk_while { |left, right| left[0] == right[0] }.each do |batch|
          marks = []
          batch.each do |at, _order, index, kind, adverse, close|
            plan = plans.fetch(index)
            case kind
            when :open
              fee_open = @notional * @fee
              if @cash < @notional + fee_open
                rejections["insufficient_cash"] += 1
              elsif @exposure + @notional > @max_exposure * (@cash + @exposure)
                rejections["exposure_cap"] += 1
              else
                entry = plan[:open_price] * (plan[:long] ? 1 + @slippage : 1 - @slippage)
                @cash -= @notional + fee_open
                @exposure += @notional
                @marked += @notional
                @fees += fee_open
                @open[index] = { entry: entry, fee: fee_open, value: @notional }
                # The leader closed before the follower's entry bar ended: in and out at one quote.
                settle(index, plan, positions[index], plan[:close_price], at) if plan[:close_at] == at
              end
            when :close
              settle(index, plan, positions[index], plan[:close_price], at) if @open.key?(index)
              realized = @cash + @exposure
              realized_peak = realized if realized > realized_peak
              realized_drawdown = [realized_drawdown, (realized_peak - realized) / realized_peak].max
            when :mark
              marks << [index, plan, adverse, close, at] if @open.key?(index)
            end
          end
          # Every open copy takes its worst price of the bar at once: the true low of the book
          # inside a bar is unknown, and this bound can only overstate the drawdown.
          marks.each { |index, plan, adverse, _close, _at| revalue(index, plan, adverse) }
          equity = @cash + @marked
          max_drawdown = [max_drawdown, (peak - equity) / peak].max
          marks.each do |index, plan, _adverse, close, at|
            if @open[index][:value].zero?
              settle(index, plan, positions[index], nil, at)
            elsif close
              revalue(index, plan, close)
            end
          end
          equity = @cash + @marked
          peak = equity if equity > peak
          max_drawdown = [max_drawdown, (peak - equity) / peak].max
        end
        raise ArgumentError, "every position must close" unless @open.empty?

        net = @cash - @initial
        wins = @trades.count { |trade| BigDecimal(trade["pnl"]).positive? }
        {
          "model" => MODELS.fetch(@pricing),
          "pricing" => @pricing,
          "follower_delay_seconds" => quoted? ? @delay : nil,
          "mark_bar" => quoted? ? quotes["mark_bar"] : nil,
          "positions" => positions.size,
          "copied" => @trades.size,
          "rejected" => rejections.values.sum,
          "rejections" => rejections,
          "period" => { "from" => positions.map { |row| row["opened_at"].to_s }.min, "to" => positions.map { |row| row["closed_at"].to_s }.max },
          "starting_cash" => num(@initial),
          "equity" => num(@cash),
          "net_pnl" => num(net),
          "return" => num(net / @initial),
          "fees" => num(@fees),
          "baseline_pnl" => num(@baseline),
          "cost_drag" => num(@baseline - net),
          "delay_drag" => num(@baseline - @unslipped),
          "wins" => wins,
          "losses" => @trades.size - wins,
          "win_rate" => @trades.empty? ? nil : num(BigDecimal(wins) / @trades.size),
          "max_drawdown" => num(max_drawdown),
          "max_drawdown_realized" => num(realized_drawdown),
          "liquidated" => @trades.count { |trade| trade["liquidated"] },
          "trades" => @trades
        }
      end

      private

      # Where and when this copy would trade, or nil when the market gave no quote for it.
      def plan(position, quote)
        long = side(position) == "long"
        leader = { long: long, leader_open: price(position, "open_price"), leader_close: price(position, "close_price") }
        opened = position.fetch("opened_at_ms")
        closed = position.fetch("closed_at_ms")
        raise ArgumentError, "position times are invalid" unless opened.is_a?(Integer) && closed.is_a?(Integer) && closed >= opened
        unless quoted?
          return leader.merge(open_at: opened, close_at: closed, open_price: leader[:leader_open], close_price: leader[:leader_close], path: [])
        end
        return nil unless quote
        open_at, open_price = quote.fetch("entry")
        close_at, close_price = quote.fetch("exit")
        # A fill before its own signal would be lookahead, whatever the quote source says.
        raise ArgumentError, "quote precedes its signal" if open_at < opened + delay_ms || close_at < closed + delay_ms
        leader.merge(open_at: open_at, close_at: close_at, open_price: decimal(open_price, "entry quote"),
                     close_price: decimal(close_price, "exit quote"), path: quote.fetch("path"))
      end

      def value(held, plan, price)
        ratio = price / held[:entry]
        worth = @notional * (plan[:long] ? ratio : 2 - ratio)
        worth.negative? ? BigDecimal("0") : worth
      end

      def revalue(index, plan, price)
        held = @open.fetch(index)
        worth = value(held, plan, price)
        @marked += worth - held[:value]
        held[:value] = worth
      end

      # `quote` is the raw exit price; nil means the copy was wiped out on the way.
      def settle(index, plan, position, quote, at)
        held = @open.delete(index)
        if quote
          exit_price = quote * (plan[:long] ? 1 - @slippage : 1 + @slippage)
          gross = [move(plan, held[:entry], exit_price), -@notional].max
        else
          exit_price = plan[:long] ? BigDecimal("0") : held[:entry] * 2
          gross = -@notional
        end
        fee_close = (@notional + gross) * @fee
        @cash += @notional + gross - fee_close
        @exposure -= @notional
        @marked -= held[:value]
        @fees += fee_close
        @baseline += move(plan, plan[:leader_open], plan[:leader_close])
        @unslipped += quote ? [move(plan, plan[:open_price], quote), -@notional].max : -@notional
        @trades << {
          "sub_position_id" => position["sub_position_id"].to_s,
          "instrument" => position["instrument"].to_s,
          "side" => plan[:long] ? "long" : "short",
          "opened_at" => position["opened_at"].to_s,
          "closed_at" => position["closed_at"].to_s,
          "entry_at" => iso(plan[:open_at]),
          "exit_at" => iso(at),
          "leader_entry" => num(plan[:leader_open]),
          "leader_exit" => num(plan[:leader_close]),
          "entry" => num(held[:entry]),
          "exit" => num(exit_price),
          "liquidated" => quote.nil?,
          "pnl" => num(gross - held[:fee] - fee_close)
        }
      end

      def move(plan, from, to)
        change = to / from - 1
        @notional * (plan[:long] ? change : -change)
      end

      def side(position)
        value = position["side"]
        raise ArgumentError, "position side must be long or short" unless %w[long short].include?(value)
        value
      end

      def price(position, name)
        decimal(position[name], name)
      end

      def decimal(value, name, zero: false)
        number = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s, exception: false)
        valid = number&.finite? && (zero ? number >= 0 : number.positive?)
        raise ArgumentError, "#{name} must be #{zero ? 'a non-negative' : 'a positive'} decimal" unless valid
        number
      end

      def integer(value, name, range)
        number = value.is_a?(Integer) ? value : Integer(value.to_s, 10, exception: false)
        raise ArgumentError, "#{name} must be an integer in #{range}" unless number.is_a?(Integer) && range.cover?(number)
        number
      end

      def iso(at_ms)
        Time.at(Rational(at_ms, 1000)).utc.iso8601(3)
      end

      def num(value)
        value.round(MONEY).to_s("F")
      end
    end
  end
end
