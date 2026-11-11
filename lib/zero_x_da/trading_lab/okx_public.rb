# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module ZeroXDA
  module TradingLab
    # Shared transport for public, unauthenticated OKX REST endpoints. It only issues GET
    # requests, sends no credentials and signs nothing, so it cannot place or cancel orders.
    class OkxPublic
      class Error < StandardError; end
      class RateLimited < Error; end
      class UnknownInstrument < Error; end

      ORIGIN = "https://www.okx.com"
      MAX_BODY_BYTES = 1_048_576
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

      def self.monotonic
        -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      end

      # OKX limits are per IP and per endpoint, so every endpoint family passes the throttle
      # its instances share and the minimum spacing its documented limit allows.
      def initialize(throttle:, min_interval:, transport: self.class.default_transport, clock: self.class.monotonic,
                     sleeper: ->(seconds) { sleep(seconds) }, origin: ORIGIN)
        @origin = origin
        @transport = transport
        @clock = clock
        @sleeper = sleeper
        @throttle = throttle
        @min_interval = min_interval
      end

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

      # The `data` array of a successful envelope; `rows` is the class every element must have.
      def data(path, query, rows: Hash)
        document = get(path, query)
        raise Error, "OKX response is not an object" unless document.is_a?(Hash)
        code = document["code"].to_s
        raise RateLimited, "OKX rate limit reached" if code == "50011"
        raise UnknownInstrument, "OKX does not list this instrument" if code == "51001"
        raise Error, "OKX error #{code}: #{document['msg']}" unless code == "0"
        data = document["data"]
        raise Error, "OKX response has no data" unless data.is_a?(Array) && data.all?(rows)
        data
      end

      private

      def throttle
        @throttle[:lock].synchronize do
          now = @clock.call
          last = @throttle[:last_request_at]
          if last
            wait = @min_interval - (now - last)
            if wait.positive?
              @sleeper.call(wait)
              now += wait
            end
          end
          @throttle[:last_request_at] = now
        end
      end
    end
  end
end
