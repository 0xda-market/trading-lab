# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "net/http"
require "nokogiri"
require "openssl"
require "time"
require "uri"

module ZeroXDA
  module TradingLab
    # Reads the public web preview of a Telegram channel (https://t.me/s/<channel>).
    #
    # The preview is the page Telegram serves to anyone without an account. Reading it needs
    # no bot token, no phone number and no session, so the lab holds no Telegram credential
    # and can see only what a channel chose to publish openly. Private channels and channels
    # that disabled the preview are out of reach by design.
    class TelegramPreview
      class Error < StandardError; end
      class NoPreview < Error; end

      ORIGIN = "https://t.me"
      CHANNEL = /\A[a-z][a-z0-9_]{3,31}\z/
      MAX_BODY_BYTES = 2_097_152
      MAX_TEXT_BYTES = 16_384
      MIN_INTERVAL_SECONDS = 1.0
      NETWORK_ERRORS = [SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, EOFError].freeze

      def self.channel(name)
        channel = name.to_s.delete_prefix("@").downcase
        raise ArgumentError, "channel must be a public username such as some_channel" unless CHANNEL.match?(channel)
        channel
      end

      def self.default_transport
        lambda do |uri|
          proxy = uri.find_proxy
          http = Net::HTTP.new(uri.host, uri.port, proxy&.host, proxy&.port, proxy&.user, proxy&.password)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = 5
          http.read_timeout = 15
          response = http.start { http.request(Net::HTTP::Get.new(uri, "accept" => "text/html", "user-agent" => "0xda-trading-lab")) }
          [response.code.to_i, response.body.to_s]
        rescue *NETWORK_ERRORS => error
          raise Error, "Telegram request failed: #{error.class}"
        end
      end

      def initialize(transport: self.class.default_transport, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     sleeper: ->(seconds) { sleep(seconds) }, origin: ORIGIN)
        @transport = transport
        @clock = clock
        @sleeper = sleeper
        @origin = origin
        @last = nil
      end

      # The newest posts of a channel, oldest first; `before` pages back from a message id.
      # Each is { "message_id", "published_at", "text", "edited" }.
      def page(name, before: nil)
        channel = self.class.channel(name)
        raise ArgumentError, "before must be a positive message id" unless before.nil? || (before.is_a?(Integer) && before.positive?)
        uri = URI("#{@origin}/s/#{channel}#{before ? "?before=#{before}" : ''}")
        wait
        status, body = @transport.call(uri)
        # Telegram redirects /s/<name> to /<name> when there is nothing public to show.
        raise NoPreview, "#{channel} has no public preview" if [301, 302, 404].include?(status)
        raise Error, "Telegram responded with HTTP #{status}" unless status == 200
        raise Error, "Telegram response is too large" if body.bytesize > MAX_BODY_BYTES
        messages(Nokogiri::HTML5(body.dup.force_encoding(Encoding::UTF_8).scrub, max_errors: 0), channel)
      end

      private

      def wait
        now = @clock.call
        pause = @last ? MIN_INTERVAL_SECONDS - (now - @last) : 0
        if pause.positive?
          @sleeper.call(pause)
          now += pause
        end
        @last = now
      end

      def messages(document, channel)
        raise NoPreview, "#{channel} has no public preview" unless document.at_css(".tgme_channel_info, .tgme_widget_message")
        rows = document.css("div.tgme_widget_message[data-post]").filter_map do |node|
          owner, id = node["data-post"].to_s.split("/", 2)
          # A forwarded or quoted post of another channel is not this channel's message.
          next unless owner.to_s.downcase == channel && /\A[1-9]\d{0,14}\z/.match?(id.to_s)
          stamp = node.at_css("a.tgme_widget_message_date time[datetime]")&.[]("datetime")
          raise Error, "Telegram post #{id} has no timestamp" unless stamp
          { "message_id" => Integer(id, 10), "published_at" => Time.iso8601(stamp).utc.iso8601(3),
            "text" => text(node), "edited" => node.at_css(".tgme_widget_message_meta").to_s.match?(/\bedited\b/i) }
        end
        rows.uniq { |row| row["message_id"] }.sort_by { |row| row["message_id"] }
      rescue ArgumentError
        raise Error, "Telegram post timestamp is invalid"
      end

      # Visible text with line breaks kept; a post without text (media only) is "".
      def text(node)
        body = node.at_css(".tgme_widget_message_text.js-message_text") || node.at_css(".tgme_widget_message_bubble > .tgme_widget_message_text")
        return "" unless body
        body = body.dup
        body.css("br").each { |br| br.replace("\n") }
        body.text.gsub(" ", " ").gsub(/[ \t]+/, " ").gsub(/ ?\n ?/, "\n").strip.byteslice(0, MAX_TEXT_BYTES).scrub("")
      end
    end
  end
end
