# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "base64"
require "openssl"
require "socket"
require "timeout"
require "uri"
require "websocket/driver"

module ZeroXDA
  module TradingLab
    # Minimal blocking WebSocket text client over websocket-driver. One thread owns it:
    # `read` pumps the socket and returns the next text message.
    class WebSocketClient
      class Error < StandardError; end

      NETWORK_ERRORS = [SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, EOFError, IOError].freeze
      CHUNK = 16_384

      attr_reader :url

      def initialize(url, open_timeout: 10)
        @url = url
        @uri = URI(url)
        raise ArgumentError, "url must be ws:// or wss://" unless %w[ws wss].include?(@uri.scheme)
        @open_timeout = open_timeout
        @messages = []
        @open = false
        @failure = nil
      end

      def connect
        @socket = open_socket
        @driver = WebSocket::Driver.client(self)
        @driver.on(:open) { @open = true }
        @driver.on(:message) { |event| @messages << event.data if event.data.is_a?(String) }
        @driver.on(:error) { |event| @failure ||= "protocol error: #{event.message}" }
        @driver.on(:close) { |event| @failure ||= "closed by peer (#{event.code})" }
        @driver.start
        deadline = now + @open_timeout
        pump(deadline - now) until @open || @failure || now >= deadline
        raise Error, @failure || "handshake timed out" unless @open
        self
      rescue *NETWORK_ERRORS => error
        close
        raise Error, "connection failed: #{error.class}"
      end

      # The next text message, or nil when none arrives within `timeout` seconds.
      def read(timeout)
        deadline = now + timeout
        loop do
          return @messages.shift unless @messages.empty?
          raise Error, @failure if @failure
          remaining = deadline - now
          return nil unless remaining.positive?
          pump(remaining)
        end
      rescue *NETWORK_ERRORS => error
        raise Error, "connection lost: #{error.class}"
      end

      def send_text(text)
        @driver.text(text)
      rescue *NETWORK_ERRORS => error
        raise Error, "connection lost: #{error.class}"
      end

      def close
        @driver&.close
        @socket&.close
      rescue *NETWORK_ERRORS
        nil
      ensure
        @socket = nil
      end

      # websocket-driver writes outgoing bytes through this.
      def write(data)
        @socket.write(data)
      end

      private

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def pump(timeout)
        # TLS may hold decrypted bytes that select() on the raw socket cannot see.
        pending = @socket.respond_to?(:pending) && @socket.pending.positive?
        return unless pending || IO.select([@socket.to_io], nil, nil, timeout)
        data = @socket.read_nonblock(CHUNK, exception: false)
        return if data == :wait_readable || data == :wait_writable
        raise EOFError if data.nil?
        @driver.parse(data)
      end

      def open_socket
        port = @uri.port || (@uri.scheme == "wss" ? 443 : 80)
        # URI resolves proxies by scheme and knows none for wss, so ask as https/http.
        proxy = URI("#{@uri.scheme == 'wss' ? 'https' : 'http'}://#{@uri.host}:#{port}").find_proxy
        socket = Socket.tcp(proxy ? proxy.host : @uri.host, proxy ? proxy.port : port, connect_timeout: @open_timeout)
        tunnel(socket, proxy, port) if proxy
        return socket unless @uri.scheme == "wss"
        context = OpenSSL::SSL::SSLContext.new
        context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
        tls = OpenSSL::SSL::SSLSocket.new(socket, context)
        tls.sync_close = true
        tls.hostname = @uri.host
        tls.connect
        tls.post_connection_check(@uri.host)
        tls
      end

      def tunnel(socket, proxy, port)
        request = "CONNECT #{@uri.host}:#{port} HTTP/1.1\r\nHost: #{@uri.host}:#{port}\r\n"
        request += "Proxy-Authorization: Basic #{Base64.strict_encode64("#{URI.decode_www_form_component(proxy.user)}:#{URI.decode_www_form_component(proxy.password.to_s)}")}\r\n" if proxy.user
        socket.write("#{request}\r\n")
        status = socket.gets.to_s
        raise Error, "proxy refused the tunnel: #{status.strip}" unless status.match?(%r{\AHTTP/1\.[01] 200})
        while (line = socket.gets) && line != "\r\n"; end
      end
    end
  end
end
