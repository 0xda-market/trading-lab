# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "bigdecimal"
require "json"
require "net/http"
require "openssl"
require "time"
require "uri"

module ZeroXDA
  module TradingLab
    # Read-only client for the public OKX lead trader leaderboard
    # (GET /api/v5/copytrading/public-lead-traders). It sends no credentials,
    # signs nothing and cannot place, copy or cancel orders.
    class OkxLeadTraders
      class Error < StandardError; end
      class RateLimited < Error; end

      ORIGIN = "https://www.okx.com"
      PATH = "/api/v5/copytrading/public-lead-traders"
      POSITIONS_PATH = "/api/v5/copytrading/public-subpositions-history"
      MAX_POSITION_PAGES = 3
      SUB_POSITION_ID = /\A\d{1,24}\z/
      INSTRUMENT = /\A[A-Z0-9]{1,20}-[A-Z0-9]{2,10}-SWAP\z/
      # Documented limit: 5 requests per 2 seconds per IP.
      MIN_INTERVAL_SECONDS = 0.4
      MAX_BODY_BYTES = 1_048_576
      SORT_TYPES = %w[overview pnl aum win_ratio pnl_ratio current_copy_trader_pnl].freeze
      MIN_LEAD_DAYS = { 7 => "1", 30 => "2", 90 => "3", 180 => "4" }.freeze
      OPTIONS = %w[sort state min_lead_days min_assets max_assets min_aum max_aum data_version page limit].freeze
      UNIQUE_CODE = /\A(?:[0-9A-Za-z]{16}|[0-9]{18})\z/
      # The documented limit is per IP, so instances share one throttle by default.
      SHARED_THROTTLE = { lock: Mutex.new, last_request_at: nil }

      NETWORK_ERRORS = [SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, EOFError].freeze

      # Honors https_proxy/no_proxy (Net::HTTP's own :ENV lookup reads only http_proxy).
      def self.default_transport
        lambda do |uri|
          proxy = uri.find_proxy
          http = Net::HTTP.new(uri.host, uri.port, proxy&.host, proxy&.port, proxy&.user, proxy&.password)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = 5
          http.read_timeout = 10
          http.start do
            request = Net::HTTP::Get.new(uri)
            request["accept"] = "application/json"
            request["user-agent"] = "0xda-trading-lab"
            http.request(request) do |response|
              body = +""
              response.read_body do |chunk|
                body << chunk
                raise Error, "OKX response is too large" if body.bytesize > MAX_BODY_BYTES
              end
              return [response.code.to_i, body]
            end
          end
        rescue *NETWORK_ERRORS => error
          raise Error, "OKX request failed: #{error.class}"
        end
      end

      def initialize(transport: self.class.default_transport, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: ->(seconds) { sleep(seconds) }, throttle: SHARED_THROTTLE, origin: ORIGIN)
        @origin = origin
        @transport = transport
        @clock = clock
        @sleeper = sleeper
        @throttle = throttle
      end

      def ranks(options = {})
        query = query_for(options)
        normalize(get(PATH, query), query)
      end

      # Closed lead positions of the last 3 months (OKX public-subpositions-history), oldest first.
      # Reads at most MAX_POSITION_PAGES pages of 100, paging backwards with `after`.
      def positions(unique_code, max_pages: MAX_POSITION_PAGES)
        raise ArgumentError, "unique_code is invalid" unless UNIQUE_CODE.match?(unique_code.to_s)
        raise ArgumentError, "max_pages must be 1..#{MAX_POSITION_PAGES}" unless max_pages.is_a?(Integer) && (1..MAX_POSITION_PAGES).cover?(max_pages)
        rows = []
        after = nil
        max_pages.times do
          query = { "instType" => "SWAP", "uniqueCode" => unique_code.to_s, "limit" => "100" }
          query["after"] = after if after
          data = envelope_data(get(POSITIONS_PATH, query))
          page = data.map { |row| position(row, unique_code.to_s) }
          rows.concat(page)
          break if page.size < 100
          after = page.map { |row| row["sub_position_id"] }.min_by(&:to_i)
        end
        unique = rows.uniq { |row| row["sub_position_id"] }
        raise Error, "OKX returned duplicate positions" unless unique.size == rows.size
        rows.sort_by { |row| [row["opened_at_ms"], row["sub_position_id"].to_i] }
      end

      private

      def get(path, query)
        uri = URI("#{@origin}#{path}?#{URI.encode_www_form(query)}")
        throttle
        status, body = @transport.call(uri)
        raise RateLimited, "OKX rate limit reached" if status == 429
        raise Error, "OKX responded with HTTP #{status}" unless status == 200
        raise Error, "OKX response is too large" if body.bytesize > MAX_BODY_BYTES # injected transports
        JSON.parse(body)
      rescue JSON::ParserError
        raise Error, "OKX response is not JSON"
      end

      def envelope_data(document)
        raise Error, "OKX response is not an object" unless document.is_a?(Hash)
        code = document["code"].to_s
        raise RateLimited, "OKX rate limit reached" if code == "50011"
        raise Error, "OKX error #{code}: #{document['msg']}" unless code == "0"
        data = document["data"]
        raise Error, "OKX response has no data" unless data.is_a?(Array) && data.all?(Hash)
        data
      end

      def position(row, unique_code)
        raise Error, "OKX position belongs to another trader" unless row["uniqueCode"] == unique_code
        side = row["posSide"]
        quantity = BigDecimal(decimal(row, "subPos"))
        side = quantity.negative? ? "short" : "long" if side == "net"
        raise Error, "OKX posSide is invalid" unless %w[long short].include?(side)
        opened = Integer(field(row, "openTime", /\A\d{13}\z/), 10)
        closed = Integer(field(row, "closeTime", /\A\d{13}\z/), 10)
        raise Error, "OKX position closes before it opens" if closed < opened
        open_price = decimal(row, "openAvgPx")
        close_price = decimal(row, "closeAvgPx")
        raise Error, "OKX position price is not positive" unless BigDecimal(open_price).positive? && BigDecimal(close_price).positive?
        {
          "sub_position_id" => field(row, "subPosId", SUB_POSITION_ID),
          "instrument" => field(row, "instId", INSTRUMENT),
          "side" => side,
          "leverage" => decimal(row, "lever"),
          "open_price" => open_price,
          "close_price" => close_price,
          "opened_at_ms" => opened,
          "closed_at_ms" => closed,
          "opened_at" => Time.at(Rational(opened, 1000)).utc.iso8601(3),
          "closed_at" => Time.at(Rational(closed, 1000)).utc.iso8601(3),
          "leader_pnl_ratio" => decimal(row, "pnlRatio")
        }
      end

      def query_for(options)
        raise ArgumentError, "options must be an object" unless options.is_a?(Hash)
        options = options.transform_keys(&:to_s)
        raise ArgumentError, "unknown option" unless (options.keys - OPTIONS).empty?
        query = { "instType" => "SWAP" }
        if options.key?("sort")
          raise ArgumentError, "sort must be one of #{SORT_TYPES.join(', ')}" unless SORT_TYPES.include?(options["sort"].to_s)
          query["sortType"] = options["sort"].to_s
        end
        if options.key?("state")
          raise ArgumentError, "state must be all or vacancy" unless %w[all vacancy].include?(options["state"].to_s)
          query["state"] = options["state"].to_s == "vacancy" ? "1" : "0"
        end
        if options.key?("min_lead_days")
          code = MIN_LEAD_DAYS[integer(options["min_lead_days"], "min_lead_days")]
          raise ArgumentError, "min_lead_days must be one of #{MIN_LEAD_DAYS.keys.join(', ')}" unless code
          query["minLeadDays"] = code
        end
        { "min_assets" => "minAssets", "max_assets" => "maxAssets", "min_aum" => "minAum", "max_aum" => "maxAum" }.each do |key, param|
          query[param] = amount(options[key], key) if options.key?(key)
        end
        [%w[minAssets maxAssets], %w[minAum maxAum]].each do |low, high|
          next unless query.key?(low) && query.key?(high)
          raise ArgumentError, "#{low} must not exceed #{high}" if BigDecimal(query[low]) > BigDecimal(query[high])
        end
        if options.key?("data_version")
          raise ArgumentError, "data_version must be 14 digits" unless /\A\d{14}\z/.match?(options["data_version"].to_s)
          query["dataVer"] = options["data_version"].to_s
        end
        if options.key?("page")
          page = integer(options["page"], "page")
          raise ArgumentError, "page must be positive" unless page.positive?
          query["page"] = page.to_s
        end
        if options.key?("limit")
          limit = integer(options["limit"], "limit")
          raise ArgumentError, "limit must be between 1 and 20" unless (1..20).cover?(limit)
          query["limit"] = limit.to_s
        end
        query
      end

      def throttle
        @throttle[:lock].synchronize do
          now = @clock.call
          last = @throttle[:last_request_at]
          if last
            wait = MIN_INTERVAL_SECONDS - (now - last)
            if wait.positive?
              @sleeper.call(wait)
              now += wait
            end
          end
          @throttle[:last_request_at] = now
        end
      end

      def normalize(document, query)
        raise Error, "OKX response is not an object" unless document.is_a?(Hash)
        code = document["code"].to_s
        raise RateLimited, "OKX rate limit reached" if code == "50011"
        raise Error, "OKX error #{code}: #{document['msg']}" unless code == "0"
        pages = document["data"]
        raise Error, "OKX response has no data" unless pages.is_a?(Array) && pages.size == 1 && pages.first.is_a?(Hash)
        page = pages.first
        ranks = page["ranks"]
        raise Error, "OKX response has no ranks" unless ranks.is_a?(Array)
        version = field(page, "dataVer", /\A\d{14}\z/)
        # OKX silently serves the latest snapshot for an unknown dataVer; never mix snapshots.
        if query.key?("dataVer") && version != query["dataVer"]
          raise Error, "OKX data version #{query['dataVer']} is no longer available (got #{version})"
        end
        {
          "source" => "okx",
          "endpoint" => PATH,
          "instrument_type" => query["instType"],
          "sort" => query.fetch("sortType", "overview"),
          "data_version" => version,
          "page" => Integer(query.fetch("page", "1")),
          "limit" => Integer(query.fetch("limit", "10")),
          "total_pages" => count(page, "totalPage"),
          "traders" => ranks.map { |rank| trader(rank) }
        }
      end

      # Order is preserved exactly as OKX ranked it; nothing is re-sorted.
      def trader(rank)
        raise Error, "OKX rank is not an object" unless rank.is_a?(Hash)
        copy_traders = count(rank, "copyTraderNum")
        max_copy_traders = count(rank, "maxCopyTraderNum")
        instruments = rank.fetch("traderInsts", [])
        raise Error, "OKX traderInsts is invalid" unless instruments.is_a?(Array) && instruments.all?(String)
        ratios = rank.fetch("pnlRatios", [])
        raise Error, "OKX pnlRatios is invalid" unless ratios.is_a?(Array) && ratios.all?(Hash)
        {
          "unique_code" => field(rank, "uniqueCode", UNIQUE_CODE),
          "nickname" => rank["nickName"].to_s,
          "margin_currency" => field(rank, "ccy", /\A[A-Z0-9]{2,10}\z/),
          "lead_days" => count(rank, "leadDays"),
          "pnl_90d" => decimal(rank, "pnl"),
          "pnl_ratio_90d" => decimal(rank, "pnlRatio"),
          "win_ratio" => decimal(rank, "winRatio"),
          "aum" => decimal(rank, "aum"),
          "copy_traders" => copy_traders,
          "max_copy_traders" => max_copy_traders,
          "accumulated_copy_traders" => count(rank, "accCopyTraderNum"),
          # Raw OKX copyState: "0" non-copy, "1" copy. Not the same fact as vacancy.
          "copy_state" => field(rank, "copyState", /\A[01]\z/),
          # Numerical capacity only (copyTraderNum < maxCopyTraderNum). It does not prove
          # the trader is eligible to be copied; OKX documents no such field here.
          "has_capacity" => copy_traders < max_copy_traders,
          "instruments" => instruments,
          "daily_pnl_ratios" => ratios.map do |ratio|
            { "begin_at" => millis(ratio, "beginTs"), "pnl_ratio" => decimal(ratio, "pnlRatio") }
          end
        }
      end

      def field(hash, name, pattern)
        value = hash[name]
        raise Error, "OKX #{name} is invalid" unless value.is_a?(String) && pattern.match?(value)
        value
      end

      def count(hash, name)
        Integer(field(hash, name, /\A\d{1,12}\z/), 10)
      end

      # OKX sends small values in scientific notation (e.g. daily pnlRatio "-1.0E-4"); the
      # exponent is bounded and the result is normalized to plain decimal notation.
      def decimal(hash, name)
        value = field(hash, name, /\A-?\d+(?:\.\d+)?(?:[eE][-+]?\d{1,3})?\z/)
        BigDecimal(value).to_s("F")
      end

      def millis(hash, name)
        Time.at(Rational(Integer(field(hash, name, /\A\d{13}\z/), 10), 1000)).utc.iso8601(3)
      end

      def integer(value, name)
        Integer(value.to_s, 10)
      rescue ArgumentError
        raise ArgumentError, "#{name} must be an integer"
      end

      def amount(value, name)
        # OKX rejects decimal notation here ("10.0" -> code 51000), so only whole USDT.
        raise ArgumentError, "#{name} must be a whole non-negative USDT amount" unless /\A\d{1,15}\z/.match?(value.to_s)
        Integer(value.to_s, 10).to_s
      end
    end
  end
end
