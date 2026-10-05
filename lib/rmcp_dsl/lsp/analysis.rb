# frozen_string_literal: true

module RmcpDsl
  module Lsp
    # What the compiler says about one version of one document. Nothing is cached across versions: a new
    # Analysis is built per change (compiling a DSL file takes milliseconds). Positions are the compiler's
    # (1-based line, 1-based byte column); see Lsp.
    class Analysis
      # message: text without the "FILE:LINE:COL:" prefix. end_col is 1-based exclusive, on the same line.
      Diagnostic = Struct.new(:line, :col, :end_col, :message, :suggestions, keyword_init: true)

      attr_reader :path, :text, :lines, :types, :diagnostics

      # `types` entries are hashes with symbol keys: line, col, end_line, end_col, kind ("parameter", "local",
      # "expression", "field", "helper" or "output"), type (a display string like "T.nilable(String)") and
      # optionally name. They cover everything the compiler typed before it stopped, so hover keeps working
      # above a mistake.
      def initialize(path, text)
        @path = path
        @text = text
        @lines = text.split("\n", -1)
        @diagnostics = []
        collector = TypeNames::Collector.new(path)
        begin
          Sources.with(path, text) { Reader.new(path, types: collector).read } # the editor's text, not the file on disk
        rescue CompileError => e
          @diagnostics = parse_errors(e)
        rescue StandardError => e # a compiler bug must not take the editor down
          @diagnostics = [Diagnostic.new(line: 1, col: 1, end_col: 2, message: "rmcp_dsl internal error: #{e.class}: #{e.message}", suggestions: [])]
        end
        @types = collector.entries
      end

      def ok? = @diagnostics.empty?

      def line_text(line) = @lines[line - 1].to_s

      # Entries containing a position, narrowest first. line and byte_col are 1-based.
      def types_at(line, byte_col)
        found = @types.select do |t|
          (line > t[:line] || (line == t[:line] && byte_col >= t[:col])) &&
            (line < t[:end_line] || (line == t[:end_line] && byte_col < t[:end_col]))
        end
        found.sort_by { |t| [t[:end_line] - t[:line], t[:end_col] - t[:col]] }
      end

      private

      # CompileError#message is "FILE:LINE:COL: text", one per line for syntax errors; a line that does not start
      # with that prefix continues the previous message. Suggestions belong to the last (only) semantic error.
      def parse_errors(error)
        prefix = /\A#{Regexp.escape(@path)}:(\d+):(\d+): (.*)\z/
        out = []
        error.message.to_s.split("\n").each do |row|
          if (m = row.match(prefix))
            out << { line: m[1].to_i, col: m[2].to_i, message: m[3] }
          elsif out.any?
            out.last[:message] += "\n#{row}"
          else
            out << { line: 1, col: 1, message: row }
          end
        end
        out = [{ line: 1, col: 1, message: error.message.to_s }] if out.empty?
        out.each_with_index.map do |d, i|
          Diagnostic.new(line: d[:line], col: d[:col], end_col: token_end(d[:line], d[:col]), message: d[:message],
                         suggestions: i == out.size - 1 ? error.suggestions : [])
        end
      end

      # The error position is the start of the offending node; underline its first token, or the rest of the
      # line when that is not a word.
      def token_end(line, col)
        text = line_text(line)
        rest = text.byteslice(col - 1, text.bytesize).to_s
        word = rest[/\A[A-Za-z0-9_?!:@$.]+/]
        word ||= rest.rstrip
        col + [word.bytesize, 1].max
      end
    end
  end
end
