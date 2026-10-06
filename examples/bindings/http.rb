# typed: true
# An HTTP client for tools that call an API: GET and POST with the standard library of the `ureq` crate. Every function
# gives the response body, or nil when the request fails or the answer is not a success (2xx), so the DSL decides what
# a failure means (`|| raise("...")`). A request gives up after ten seconds. The address is not restricted: when a tool
# lets the client choose it, pair this with Net.public_address? as webkit does. A key or token goes in as an argument,
# so a `secret: true` setting can be passed to it and still never be printed or returned by a body.
module Http
  extend T::Sig
  extend RmcpDsl::BindingDsl

  crate "ureq", "2"

  # The body of a GET.
  rust "ureq::AgentBuilder::new().timeout(std::time::Duration::from_secs(10)).build().get(url).call().ok().and_then(|r| r.into_string().ok())"
  no_reference "it needs a server to talk to; test/e2e_apikit.rb runs the real thing against a local one"
  sig { params(url: String).returns(T.nilable(String)) }
  def self.get(url) = raise(NotImplementedError, "no Ruby stand-in")

  # A GET with an `Authorization: Bearer <token>` header.
  rust "ureq::AgentBuilder::new().timeout(std::time::Duration::from_secs(10)).build().get(url).set(\"Authorization\", &format!(\"Bearer {token}\")).call().ok().and_then(|r| r.into_string().ok())"
  no_reference "it needs a server to talk to; test/e2e_apikit.rb runs the real thing against a local one"
  sig { params(url: String, token: String).returns(T.nilable(String)) }
  def self.get_bearer(url, token) = raise(NotImplementedError, "no Ruby stand-in")

  # A GET with one header of your choice, such as `X-Api-Key`.
  rust "ureq::AgentBuilder::new().timeout(std::time::Duration::from_secs(10)).build().get(url).set(name, value).call().ok().and_then(|r| r.into_string().ok())"
  no_reference "it needs a server to talk to; test/e2e_apikit.rb runs the real thing against a local one"
  sig { params(url: String, name: String, value: String).returns(T.nilable(String)) }
  def self.get_with_header(url, name, value) = raise(NotImplementedError, "no Ruby stand-in")

  # A POST of a JSON text with an `Authorization: Bearer <token>` header.
  rust "ureq::AgentBuilder::new().timeout(std::time::Duration::from_secs(10)).build().post(url).set(\"Authorization\", &format!(\"Bearer {token}\")).set(\"Content-Type\", \"application/json\").send_string(body).ok().and_then(|r| r.into_string().ok())"
  no_reference "it needs a server to talk to; test/e2e_apikit.rb runs the real thing against a local one"
  sig { params(url: String, body: String, token: String).returns(T.nilable(String)) }
  def self.post_json_bearer(url, body, token) = raise(NotImplementedError, "no Ruby stand-in")
end
