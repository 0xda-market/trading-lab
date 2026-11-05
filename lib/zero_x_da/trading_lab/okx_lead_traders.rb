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
          http.use_ssl = true
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

      def initialize(transport: self.class.default_transport, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: ->(seconds) { sleep(seconds) }, throttle: SHARED_THROTTLE)
        @transport = transport
        @clock = clock
        @sleeper = sleeper
        @throttle = throttle
      end

      def ranks(options = {})
        query = query_for(options)
        uri = URI("#{ORIGIN}#{PATH}?#{URI.encode_www_form(query)}")
        throttle
        status, body = @transport.call(uri)
        raise RateLimited, "OKX rate limit reached" if status == 429
        raise Error, "OKX responded with HTTP #{status}" unless status == 200
        raise Error, "OKX response is too large" if body.bytesize > MAX_BODY_BYTES # injected transports
        normalize(JSON.parse(body), query)
      rescue JSON::ParserError
        raise Error, "OKX response is not JSON"
      end

      private

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
          # Derived from the two counts, matching the state=1 "has vacancy" filter.
          "has_vacancy" => copy_traders < max_copy_traders,
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

      def decimal(hash, name)
        value = field(hash, name, /\A-?\d+(?:\.\d+)?\z/)
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
        number = BigDecimal(value.to_s, exception: false)
        raise ArgumentError, "#{name} must be a finite non-negative number" unless number&.finite? && number >= 0
        number.to_s("F")
      end
    end
  end
end
