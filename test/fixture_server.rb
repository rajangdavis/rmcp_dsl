# frozen_string_literal: true

# Hermetic HTTP fixture for fetchkit's end-to-end test. It listens on loopback only (127.0.0.1,
# and [::1] when the machine has IPv6), prints "PORT6 <n>" if IPv6 is available and then
# "PORT <n>", and serves fixed routes. Not part of the product.
require "socket"

def respond(sock, status, headers, body, head_only: false)
  sock.write "HTTP/1.1 #{status}\r\n"
  headers.each { |k, v| sock.write "#{k}: #{v}\r\n" }
  sock.write "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n"
  sock.write body unless head_only
end

ROUTES = {
  "/" => ["200 OK", { "Content-Type" => "text/html" }, "<html><body><h1>fixture page</h1></body></html>"],
  "/page" => ["200 OK", { "Content-Type" => "text/html" },
              %q(<html><head><title>Fixture title</title></head><body><h1>Main   heading</h1><ul><li class="item"><a href="/one">One</a></li><li class="item"><a href="https://example.org/two">Two</a></li><li class="item">Three <b>bold</b></li></ul><p id="x">Hello &amp; goodbye</p></body></html>)],
  "/404" => ["404 Not Found", {}, "nope"],
  "/redir" => ["302 Found", { "Location" => "/" }, ""],
  "/loop1" => ["302 Found", { "Location" => "/loop2" }, ""],
  "/loop2" => ["302 Found", { "Location" => "/loop1" }, ""],
  "/meta" => ["302 Found", { "Location" => "http://169.254.169.254/latest/meta-data/" }, ""],
  "/noloc" => ["302 Found", {}, ""],
  "/big" => ["200 OK", { "Content-Type" => "text/plain" }, "a" * 2_000_000],
  "/bytes" => ["200 OK", { "Content-Type" => "application/octet-stream" }, "ok \xFF\xFE end".b]
}.freeze

def serve(server)
  Thread.new do
    loop do
      Thread.new(server.accept) do |sock|
        line = sock.gets.to_s
        method, path, = line.split
        while (header = sock.gets) && header != "\r\n"; end
        head_only = method == "HEAD"
        if path == "/slow"
          sleep 12
          respond(sock, "200 OK", {}, "late", head_only: head_only)
        elsif (route = ROUTES[path])
          respond(sock, route[0], route[1], route[2], head_only: head_only)
        else
          respond(sock, "404 Not Found", {}, "unknown route", head_only: head_only)
        end
      rescue SystemCallError, IOError
        nil
      ensure
        sock.close
      end
    end
  end
end

v6 = begin
  TCPServer.new("::1", 0)
rescue SystemCallError, SocketError
  nil
end
v4 = TCPServer.new("127.0.0.1", 0)

puts "PORT6 #{v6.addr[1]}" if v6
puts "PORT #{v4.addr[1]}"
$stdout.flush

serve(v6) if v6
serve(v4).join
