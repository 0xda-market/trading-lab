# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "bigdecimal"
require "json"
require "time"

module ZeroXDA
  module TradingLab
    # The public OKX `tickers` WebSocket channel: no login, no key, market data only.
    # It reports the last trade and the best bid and ask, pushed at most every 100 ms when
    # something changed. It is not every trade and not order book depth.
    module OkxTickers
      URL = "wss://ws.okx.com:8443/ws/v5/public"
      SOURCE = "okx.tickers"
      DEFAULT_INSTRUMENTS = %w[BTC-USDT ETH-USDT BTC-USDT-SWAP ETH-USDT-SWAP].freeze
      INSTRUMENT = /\A[A-Z0-9]{1,20}-[A-Z0-9]{2,10}(?:-SWAP)?\z/
      MAX_INSTRUMENTS = 10
      DECIMAL = /\A\d+(?:\.\d+)?(?:[eE][-+]?\d{1,3})?\z/

      class Invalid < StandardError; end
      # OKX refused the subscription itself; reconnecting would only repeat the refusal.
      class Rejected < StandardError; end

      module_function

      def instruments(list)
        raise ArgumentError, "specify between 1 and #{MAX_INSTRUMENTS} instruments" unless list.is_a?(Array) && (1..MAX_INSTRUMENTS).cover?(list.size)
        raise ArgumentError, "instruments must look like BTC-USDT or BTC-USDT-SWAP" unless list.all? { |name| name.is_a?(String) && INSTRUMENT.match?(name) }
        raise ArgumentError, "duplicate instrument" unless list.uniq.size == list.size
        list
      end

      def subscription(list)
        JSON.generate("op" => "subscribe", "args" => instruments(list).map { |name| { "channel" => "tickers", "instId" => name } })
      end

      # Decodes one frame into ticks (usually one). Subscription acknowledgements give [].
      # `received_at` is the collector's clock at receipt and is never replaced by the
      # exchange time: using OKX's `ts` as the causal time would let a later simulation
      # see a quote before the lab actually had it.
      def ticks(message, received_at:, instruments:)
        raise ArgumentError, "received_at must be UTC" unless received_at.is_a?(Time) && received_at.utc?
        payload = JSON.parse(message)
        raise Invalid, "frame is not an object" unless payload.is_a?(Hash)
        if payload.key?("event")
          raise Rejected, "OKX rejected the subscription: #{payload['code']} #{payload['msg']}" if payload["event"] == "error"
          return []
        end
        arg = payload["arg"]
        data = payload["data"]
        raise Invalid, "unexpected frame" unless arg.is_a?(Hash) && arg["channel"] == "tickers" && data.is_a?(Array) && data.all?(Hash)
        data.map { |row| tick(row, arg["instId"], received_at, instruments) }
      rescue JSON::ParserError
        raise Invalid, "frame is not JSON"
      end

      def tick(row, subscribed, received_at, instruments)
        instrument = row["instId"]
        raise Invalid, "unexpected instrument" unless instruments.include?(instrument) && instrument == subscribed
        last = decimal(row, "last")
        bid = decimal(row, "bidPx", optional: true)
        ask = decimal(row, "askPx", optional: true)
        raise Invalid, "bid exceeds ask" if bid && ask && BigDecimal(bid) > BigDecimal(ask)
        stamp = row["ts"]
        raise Invalid, "exchange time is invalid" unless stamp.is_a?(String) && /\A\d{13}\z/.match?(stamp)
        {
          "kind" => "tick",
          # Replay symbols carry no separator; the exact OKX id stays in "instrument".
          "symbol" => instrument.delete("-"),
          "price" => last,
          "received_at" => received_at.iso8601(6),
          "source" => SOURCE,
          "instrument" => instrument,
          "exchange_event_at" => Time.at(Rational(Integer(stamp, 10), 1000)).utc.iso8601(3),
          "bid" => bid,
          "ask" => ask,
          "bid_size" => decimal(row, "bidSz", optional: true, zero: true),
          "ask_size" => decimal(row, "askSz", optional: true, zero: true)
        }
      end

      # OKX sends "" for a side of the book that is empty.
      def decimal(row, name, optional: false, zero: false)
        value = row[name]
        return nil if optional && (value.nil? || value == "")
        raise Invalid, "#{name} is invalid" unless value.is_a?(String) && DECIMAL.match?(value)
        number = BigDecimal(value)
        raise Invalid, "#{name} must be positive" unless zero ? number >= 0 : number.positive?
        number.to_s("F")
      end
    end
  end
end
