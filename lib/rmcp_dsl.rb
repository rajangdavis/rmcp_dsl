# frozen_string_literal: true

require "prism"
require_relative "rmcp_dsl/version"
require "json"

module RmcpDsl
  # `suggestions` is the optional list of nearby valid names a "did you mean" hint was built from.
  class CompileError < StandardError
    attr_reader :suggestions

    def initialize(msg = nil, suggestions: [])
      super(msg)
      @suggestions = suggestions
    end
  end

  # Shared diagnostics: every error is "FILE:LINE:COL: message" (col is 1-based).
  module Diag
    def nodename(node) = node.class.name.split("::").last

    # `word:` is the misspelt name and `from:` the valid ones: the nearest are appended as "; did you mean
    # `x`?" and carried in CompileError#suggestions.
    def bad(node, msg, word: nil, from: nil)
      loc = node.location
      near = word && from ? Suggest.nearest_n(word, from) : []
      msg = "#{msg}; did you mean #{near.map { |n| "`#{n}`" }.join(" or ")}?" unless near.empty?
      raise CompileError.new("#{@path}:#{loc.start_line}:#{loc.start_column + 1}: #{msg}", suggestions: near)
    end
  end

  RUST_ESC = { "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t", "\x00" => "\\0" }.freeze

  # Escape order matters: callers double `{`/`}` AFTER esc, and esc never emits braces.
  def self.esc(str) = str.gsub(/[\\"\n\r\t\x00]/, RUST_ESC)
  def self.rstr(str) = "\"#{esc(str)}\""

  # A Rust char literal for one character (used by tr and delete).
  def self.rchar(chr)
    return "'\\''" if chr == "'"

    chr.ord.between?(0x20, 0x7e) ? "'#{chr}'" : format("'\\u{%x}'", chr.ord)
  end

  def self.read(path, types: nil) = Reader.new(path, types: types).read
end

require_relative "rmcp_dsl/suggest"
require_relative "rmcp_dsl/docs"
require_relative "rmcp_dsl/schema"
require_relative "rmcp_dsl/notify"
require_relative "rmcp_dsl/regex_translate"
require_relative "rmcp_dsl/bindings"
require_relative "rmcp_dsl/composite_types"
require_relative "rmcp_dsl/type_names"
require_relative "rmcp_dsl/body"
require_relative "rmcp_dsl/reader"
require_relative "rmcp_dsl/emit"
require_relative "rmcp_dsl/cargo_build"
require_relative "rmcp_dsl/skill"
require_relative "rmcp_dsl/rbi"
require_relative "rmcp_dsl/lsp"
