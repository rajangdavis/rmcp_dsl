# frozen_string_literal: true

# A throwaway OAuth issuer for test/e2e_httpoauth.sh: it makes an RSA key, serves its public half as a JWKS (and an OIDC
# discovery document that points at it), and writes one signed token per case into a directory. Standard library only.
#
#   ruby test/support/oauth_issuer.rb PORT TOKEN_DIR AUDIENCE     (runs until killed)
require "openssl"
require "json"
require "socket"
require "base64"
require "fileutils"

port, dir, audience = ARGV
abort "usage: oauth_issuer.rb PORT TOKEN_DIR AUDIENCE" unless port && dir && audience
issuer = "http://127.0.0.1:#{port}"
FileUtils.mkdir_p(dir)

def b64(data) = Base64.urlsafe_encode64(data, padding: false)

def int(number) = b64([number.to_s(16).then { |h| h.length.odd? ? "0#{h}" : h }].pack("H*"))

def token(key, claims, kid: "k1", alg: "RS256")
  head = b64(JSON.generate({ "alg" => alg, "typ" => "JWT", "kid" => kid }))
  body = b64(JSON.generate(claims))
  sig = alg == "none" ? "" : b64(key.sign("SHA256", "#{head}.#{body}"))
  "#{head}.#{body}.#{sig}"
end

key = OpenSSL::PKey::RSA.new(2048)
other = OpenSSL::PKey::RSA.new(2048)
jwks = JSON.generate({ "keys" => [{ "kty" => "RSA", "kid" => "k1", "use" => "sig", "alg" => "RS256",
                                    "n" => int(key.n), "e" => int(key.e) }] })
discovery = JSON.generate({ "issuer" => issuer, "jwks_uri" => "#{issuer}/keys" })

now = Time.now.to_i
good = { "iss" => issuer, "aud" => audience, "sub" => "alice", "iat" => now, "exp" => now + 3600 }
{
  "valid" => token(key, good),
  "expired" => token(key, good.merge("exp" => now - 3600)),
  "wrong_aud" => token(key, good.merge("aud" => "someone-else")),
  "wrong_iss" => token(key, good.merge("iss" => "http://evil.example")),
  "no_exp" => token(key, good.reject { |k, _| k == "exp" }),
  "bad_sig" => token(other, good),
  "unknown_kid" => token(key, good, kid: "nope"),
  "alg_none" => token(key, good, alg: "none"),
  "hs256" => "#{b64(JSON.generate({ 'alg' => 'HS256', 'typ' => 'JWT', 'kid' => 'k1' }))}.#{b64(JSON.generate(good))}.#{b64('x' * 32)}"
}.each { |name, jwt| File.write(File.join(dir, "#{name}.jwt"), jwt) }

server = TCPServer.new("127.0.0.1", port.to_i)
loop do
  client = server.accept
  Thread.new(client) do |c|
    request = c.gets.to_s
    while (line = c.gets) && line != "\r\n"; end
    payload =
      case request.split[1]
      when "/.well-known/oauth-authorization-server" then discovery # RFC 8414: the first thing the server asks for
      when "/keys" then jwks
      end
    if payload
      c.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
    else
      c.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    end
    c.close
  end
end
