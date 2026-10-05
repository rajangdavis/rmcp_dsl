# typed: true
# JSON documents held as serde_json::Value. A server cannot look inside a Json::Value from the DSL: it parses text into
# one (or takes one as a tool field, since the type says wire: true), hands it to the functions below, and may return
# one in a structured result. Nothing here has a Ruby stand-in, because a Json::Value has no Ruby literal to compare;
# test/e2e_jsonkit.sh checks the Rust over the wire.
module Json
  extend T::Sig
  extend RmcpDsl::BindingDsl

  crate "serde_json", "1"

  # Any JSON value. wire: true because serde_json::Value is serde Serialize + Deserialize and schemars JsonSchema.
  class Value < RmcpDsl::Opaque
    type_rust "serde_json::Value", wire: true
  end

  # The document in the text; nil when the text is not valid JSON.
  rust "serde_json::from_str::<serde_json::Value>(text).ok()"
  no_reference "a Json::Value has no Ruby literal to compare"
  sig { params(text: String).returns(T.nilable(Json::Value)) }
  def self.parse(text) = raise(NotImplementedError, "no Ruby stand-in")

  # The JSON text of a value, compact.
  rust "doc.to_string()"
  no_reference "a Json::Value has no Ruby literal to compare"
  sig { params(doc: Json::Value).returns(String) }
  def self.to_json(doc) = raise(NotImplementedError, "no Ruby stand-in")

  # "null", "boolean", "number", "string", "array" or "object".
  rust "match doc { serde_json::Value::Null => \"null\", serde_json::Value::Bool(_) => \"boolean\", serde_json::Value::Number(_) => \"number\", serde_json::Value::String(_) => \"string\", serde_json::Value::Array(_) => \"array\", serde_json::Value::Object(_) => \"object\" }.to_string()"
  no_reference "a Json::Value has no Ruby literal to compare"
  sig { params(doc: Json::Value).returns(String) }
  def self.kind(doc) = raise(NotImplementedError, "no Ruby stand-in")

  # The value a JSON pointer (RFC 6901: /a/0/b, or "" for the whole document) names; nil when nothing is there.
  rust "doc.pointer(path).cloned()"
  no_reference "a Json::Value has no Ruby literal to compare"
  sig { params(doc: Json::Value, path: String).returns(T.nilable(Json::Value)) }
  def self.pointer(doc, path) = raise(NotImplementedError, "no Ruby stand-in")

  # The member names of an object, sorted (serde_json keeps them sorted); nil when the value is not an object.
  rust "doc.as_object().map(|o| o.keys().cloned().collect::<Vec<String>>())"
  no_reference "a Json::Value has no Ruby literal to compare"
  sig { params(doc: Json::Value).returns(T.nilable(T::Array[String])) }
  def self.keys(doc) = raise(NotImplementedError, "no Ruby stand-in")

  # The string a value holds; nil when it is not a string.
  rust "doc.as_str().map(|s| s.to_string())"
  no_reference "a Json::Value has no Ruby literal to compare"
  sig { params(doc: Json::Value).returns(T.nilable(String)) }
  def self.string(doc) = raise(NotImplementedError, "no Ruby stand-in")

  # The integer a value holds; nil when it is not an integer that fits an i64.
  rust "doc.as_i64()"
  no_reference "a Json::Value has no Ruby literal to compare"
  sig { params(doc: Json::Value).returns(T.nilable(I64)) }
  def self.integer(doc) = raise(NotImplementedError, "no Ruby stand-in")

  # A JSON string value holding the text.
  rust "serde_json::Value::String(text.to_string())"
  no_reference "a Json::Value has no Ruby literal to compare"
  sig { params(text: String).returns(Json::Value) }
  def self.from_text(text) = raise(NotImplementedError, "no Ruby stand-in")
end
