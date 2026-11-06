# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "bigdecimal"

module ZeroXDA
  module TradingLab
    # Paper simulation of copying a lead trader's real closed positions.
    #
    # Every leader position is copied with a fixed, unlevered USDT notional, entered at the
    # leader's real average open price and exited at the leader's real average close price,
    # each moved against the follower by slippage, and charged a fee on both sides. Opens and
    # closes are processed in time order; a copy is rejected when free cash or the exposure cap
    # cannot cover it. A copy can lose at most its notional. Nothing here places an order.
    class CopyReplay
      DEFAULTS = { "starting_cash" => "1000", "trade_notional" => "100", "fee_bps" => "10",
                   "slippage_bps" => "5", "max_exposure" => "1" }.freeze
      MAX_POSITIONS = 300
      MONEY = 8

      def self.call(positions, options = {})
        new(options).call(positions)
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
        raise ArgumentError, "fee_bps and slippage_bps must be below 10000" if @fee >= 1 || @slippage >= 1
        raise ArgumentError, "max_exposure must be at most 1" if @max_exposure > 1
        raise ArgumentError, "trade_notional must not exceed starting_cash" if @notional > @initial
      end

      def call(positions)
        raise ArgumentError, "positions must be an array (maximum #{MAX_POSITIONS})" unless positions.is_a?(Array) && positions.size <= MAX_POSITIONS
        events = positions.each_with_index.flat_map do |position, index|
          raise ArgumentError, "position #{index + 1} must be an object" unless position.is_a?(Hash)
          [[position.fetch("opened_at_ms"), 1, index, :open], [position.fetch("closed_at_ms"), 0, index, :close]]
        end
        # Time order; at the same millisecond closes free cash before opens use it.
        events.sort!

        cash = @initial
        exposure = BigDecimal("0")
        open = {}
        trades = []
        rejections = Hash.new(0)
        fees = BigDecimal("0")
        baseline = BigDecimal("0")
        peak = @initial
        max_drawdown = BigDecimal("0")

        events.each do |_time, _order, index, kind|
          position = positions.fetch(index)
          if kind == :open
            fee_open = @notional * @fee
            if cash < @notional + fee_open
              rejections["insufficient_cash"] += 1
            elsif exposure + @notional > @max_exposure * (cash + exposure)
              rejections["exposure_cap"] += 1
            else
              long = side(position) == "long"
              entry = price(position, "open_price") * (long ? 1 + @slippage : 1 - @slippage)
              cash -= @notional + fee_open
              exposure += @notional
              fees += fee_open
              open[index] = { entry: entry, fee: fee_open, long: long }
            end
          else
            held = open.delete(index)
            next unless held

            exit_price = price(position, "close_price") * (held[:long] ? 1 - @slippage : 1 + @slippage)
            move = exit_price / held[:entry] - 1
            gross = @notional * (held[:long] ? move : -move)
            gross = -@notional if gross < -@notional
            fee_close = (@notional + gross) * @fee
            cash += @notional + gross - fee_close
            exposure -= @notional
            fees += fee_close
            leader_move = price(position, "close_price") / price(position, "open_price") - 1
            baseline += @notional * (held[:long] ? leader_move : -leader_move)
            pnl = gross - held[:fee] - fee_close
            trades << {
              "sub_position_id" => position["sub_position_id"].to_s,
              "instrument" => position["instrument"].to_s,
              "side" => held[:long] ? "long" : "short",
              "opened_at" => position["opened_at"].to_s,
              "closed_at" => position["closed_at"].to_s,
              "entry" => num(held[:entry]),
              "exit" => num(exit_price),
              "pnl" => num(pnl)
            }
            equity = cash + exposure
            peak = equity if equity > peak
            drawdown = (peak - equity) / peak
            max_drawdown = drawdown if drawdown > max_drawdown
          end
        end
        raise ArgumentError, "every position must close" unless open.empty?

        equity = cash
        net = equity - @initial
        wins = trades.count { |trade| BigDecimal(trade["pnl"]).positive? }
        {
          "model" => "fixed unlevered notional at the leader's real average prices, adverse slippage, fee on both sides",
          "positions" => positions.size,
          "copied" => trades.size,
          "rejected" => rejections.values.sum,
          "rejections" => rejections,
          "period" => { "from" => positions.map { |row| row["opened_at"].to_s }.min, "to" => positions.map { |row| row["closed_at"].to_s }.max },
          "starting_cash" => num(@initial),
          "equity" => num(equity),
          "net_pnl" => num(net),
          "return" => num(net / @initial),
          "fees" => num(fees),
          "baseline_pnl" => num(baseline),
          "cost_drag" => num(baseline - net),
          "wins" => wins,
          "losses" => trades.size - wins,
          "win_rate" => trades.empty? ? nil : num(BigDecimal(wins) / trades.size),
          "max_drawdown" => num(max_drawdown),
          "trades" => trades
        }
      end

      private

      def side(position)
        value = position["side"]
        raise ArgumentError, "position side must be long or short" unless %w[long short].include?(value)
        value
      end

      def price(position, name)
        value = decimal(position[name], name)
        value
      end

      def decimal(value, name, zero: false)
        number = BigDecimal(value.to_s, exception: false)
        valid = number&.finite? && (zero ? number >= 0 : number.positive?)
        raise ArgumentError, "#{name} must be #{zero ? 'a non-negative' : 'a positive'} decimal" unless valid
        number
      end

      def num(value)
        value.round(MONEY).to_s("F")
      end
    end
  end
end
