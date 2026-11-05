# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require_relative "../lib/zero_x_da/trading_lab/okx_lead_traders"

# Exercises the real Net::HTTP transport against a local plain-HTTP server.
class OkxLeadTradersTransportTest < Minitest::Test
  FIXTURE = File.read(File.expand_path("fixtures/okx_public_lead_traders.json", __dir__))
  Lead = ZeroXDA::TradingLab::OkxLeadTraders

  def serve(&respond)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      client = server.accept
      while (line = client.gets) && line != "\r\n"; end
      respond.call(client)
    rescue IOError, SystemCallError
      nil
    ensure
      client&.close
    end
    port = server.addr[1]
    [port, server, thread]
  end

  def ranks(port)
    Lead.new(transport: Lead.default_transport, origin: "http://127.0.0.1:#{port}",
             throttle: { lock: Mutex.new, last_request_at: nil }).ranks
  end

  def with_server(respond)
    port, server, thread = serve(&respond)
    yield port
  ensure
    server&.close
    thread&.kill
  end

  def test_reads_chunked_response
    respond = lambda do |io|
      io.write "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
      FIXTURE.scan(/.{1,200}/m).each { |part| io.write "#{part.bytesize.to_s(16)}\r\n#{part}\r\n" }
      io.write "0\r\n\r\n"
    end
    with_server(respond) { |port| assert_equal "540D011FDACCB47A", ranks(port)["traders"][0]["unique_code"] }
  end

  def test_rejects_oversized_chunked_body_while_streaming
    respond = lambda do |io|
      io.write "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
      chunk = "x" * 65_536
      40.times do
        io.write "#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n"
      end
      io.write "0\r\n\r\n"
    end
    with_server(respond) do |port|
      error = assert_raises(Lead::Error) { ranks(port) }
      assert_match(/too large/, error.message)
    end
  end

  def test_maps_rate_limit_status
    respond = ->(io) { io.write "HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }
    with_server(respond) { |port| assert_raises(Lead::RateLimited) { ranks(port) } }
  end

  def test_maps_dropped_connection_to_error
    with_server(->(io) { io.close }) { |port| assert_raises(Lead::Error) { ranks(port) } }
  end

  def test_maps_refused_connection_to_error
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    error = assert_raises(Lead::Error) { ranks(port) }
    assert_match(/request failed/, error.message)
  end
end
