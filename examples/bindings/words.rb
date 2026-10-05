# typed: true
# A binding with no `rust` template: the Ruby body is compiled to Rust and is the implementation.
module Words
  extend T::Sig
  extend RmcpDsl::BindingDsl

  sig { params(s: String).returns(String) }
  def self.shout(s) = s.upcase + "!"
  example :shout, "hello", expect: "HELLO!"
  example :shout, "", expect: "!"

  sig { params(s: String).returns(String) }
  def self.bracket(s) = "[#{s.strip}]"
  example :bracket, "  hi  ", expect: "[hi]"
end
