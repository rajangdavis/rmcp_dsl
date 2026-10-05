# typed: true
# URL parsing and joining, backed by the `url` crate (the WHATWG URL standard, as browsers do it). Ruby's
# URI follows an older standard and differs on edge cases, so there is no Ruby stand-in. A string that is
# not a URL gives nil (or false), never an error.
module Url
  extend T::Sig
  extend RmcpDsl::BindingDsl

  crate "url", "2"

  rust "url::Url::parse(u).is_ok()"
  no_reference "the url crate implements the WHATWG standard; Ruby's URI differs"
  sig { params(u: String).returns(T::Boolean) }
  def self.valid?(u) = raise(NotImplementedError, "no Ruby stand-in")
  example :valid?, "https://example.com/a?b=c#d", expect: true
  example :valid?, "not a url", expect: false
  example :valid?, "", expect: false

  # True when the URL carries a user name or password (http://user:pw@host/), which a fetcher should refuse.
  rust "url::Url::parse(u).map(|x| !x.username().is_empty() || x.password().is_some()).unwrap_or(false)"
  no_reference "the url crate implements the WHATWG standard; Ruby's URI differs"
  sig { params(u: String).returns(T::Boolean) }
  def self.credentials?(u) = raise(NotImplementedError, "no Ruby stand-in")
  example :credentials?, "http://user:pw@example.com/", expect: true
  example :credentials?, "http://user@example.com/", expect: true
  example :credentials?, "http://example.com/", expect: false
  example :credentials?, "not a url", expect: false

  rust "url::Url::parse(u).ok().map(|x| x.scheme().to_string())"
  no_reference "the url crate implements the WHATWG standard; Ruby's URI differs"
  sig { params(u: String).returns(T.nilable(String)) }
  def self.scheme(u) = raise(NotImplementedError, "no Ruby stand-in")
  example :scheme, "HTTPS://example.com", expect: "https"
  example :scheme, "mailto:a@b.c", expect: "mailto"
  example :scheme, "not a url", expect: nil

  # The host, lower-cased; nil when there is none (mailto:, file:) or the URL does not parse.
  rust "url::Url::parse(u).ok().and_then(|x| x.host_str().map(|h| h.to_string()))"
  no_reference "the url crate implements the WHATWG standard; Ruby's URI differs"
  sig { params(u: String).returns(T.nilable(String)) }
  def self.host(u) = raise(NotImplementedError, "no Ruby stand-in")
  example :host, "https://Example.COM:8080/a", expect: "example.com"
  example :host, "http://[::1]:3000/", expect: "[::1]"
  example :host, "mailto:a@b.c", expect: nil
  example :host, "not a url", expect: nil

  # The explicit port, or the scheme's default (80, 443, ...); nil when there is neither.
  rust "url::Url::parse(u).ok().and_then(|x| x.port_or_known_default()).map(|p| p as i64)"
  no_reference "the url crate implements the WHATWG standard; Ruby's URI differs"
  sig { params(u: String).returns(T.nilable(I64)) }
  def self.port(u) = raise(NotImplementedError, "no Ruby stand-in")
  example :port, "https://example.com", expect: 443
  example :port, "http://example.com:8080/", expect: 8080
  example :port, "http://example.com", expect: 80
  example :port, "file:///etc/hosts", expect: nil

  rust "url::Url::parse(u).ok().map(|x| x.path().to_string())"
  no_reference "the url crate implements the WHATWG standard; Ruby's URI differs"
  sig { params(u: String).returns(T.nilable(String)) }
  def self.path(u) = raise(NotImplementedError, "no Ruby stand-in")
  example :path, "https://example.com", expect: "/"
  example :path, "https://example.com/a/b?q=1#frag", expect: "/a/b"
  example :path, "not a url", expect: nil

  # Resolve rel against base the way a browser resolves a link; nil when base is not a URL or the result is not valid.
  rust "url::Url::parse(base).ok().and_then(|b| b.join(rel).ok()).map(|j| j.to_string())"
  no_reference "the url crate implements the WHATWG standard; Ruby's URI differs"
  sig { params(base: String, rel: String).returns(T.nilable(String)) }
  def self.join(base, rel) = raise(NotImplementedError, "no Ruby stand-in")
  example :join, "https://example.com/a/b", "c", expect: "https://example.com/a/c"
  example :join, "https://example.com/a/b", "/z", expect: "https://example.com/z"
  example :join, "https://example.com/a/b", "../q", expect: "https://example.com/q"
  example :join, "https://example.com/a?x=1", "?y=2", expect: "https://example.com/a?y=2"
  example :join, "https://example.com/", "http://other.org/p", expect: "http://other.org/p"
  example :join, "not a url", "x", expect: nil
end
