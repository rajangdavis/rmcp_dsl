# frozen_string_literal: true

module Rust
  # A string with Rust `str` semantics. Wraps a Ruby String; methods return
  # Rust::Str so chains stay in the Rust-typed world. Use #to_s to leave it.
  class Str
    # Rust's char::is_whitespace / str::trim set (Unicode White_Space), listed
    # explicitly so the result does not depend on the regex engine's classes.
    WHITESPACE = /[\t\n\u000B\u000C\r \u0085   -     　]/

    def initialize(str)
      raise TypeError, "Rust::Str wants a String, got #{str.class}" unless str.is_a?(String)

      @s = str.dup.freeze
    end

    def to_s = @s

    def ==(other) = other.is_a?(Str) && other.to_s == @s

    # str::trim
    def trim = Str.new(@s.sub(/\A#{WHITESPACE}+/o, "").sub(/#{WHITESPACE}+\z/o, ""))
    alias strip trim

    # str::to_lowercase / to_uppercase
    def to_lowercase = Str.new(@s.downcase)
    def to_uppercase = Str.new(@s.upcase)
    alias downcase to_lowercase
    alias upcase to_uppercase

    # str::len is the byte length, not the character count.
    def len = @s.bytesize
  end
end
