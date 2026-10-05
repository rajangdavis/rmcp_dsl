# frozen_string_literal: true

module RmcpDsl
  module Lsp
    # Go to definition: from a name used somewhere to the token that declares it. Pure; no I/O.
    #   - a CamelCase symbol (params: :Name, output: :Name, field :x, :Name, result(:Name, ...)) -> the name token of
    #     the params or output declaration
    #   - a helper call, name(args) -> the helper's name in `helper :name`
    # Anything else, and a name nothing declares, answers nil.
    module Definition
      module_function

      # line0 and utf16_col are LSP's. Returns an LSP Location {"uri", "range"}, or nil.
      def at(analysis, line0, utf16_col, uri)
        line = line0 + 1
        text = analysis.line_text(line)
        bytes = text.b
        word = word_at(bytes, Position.from_lsp(text, utf16_col) - 1)
        return nil unless word

        first, last = word
        name = bytes[first...last].force_encoding(Encoding::UTF_8)
        before = first.positive? ? bytes[first - 1] : ""
        span =
          if before == ":" && !(first > 1 && bytes[first - 2] == ":") && name.match?(/\A[A-Z]/)
            type_span(analysis, name)
          elsif !before.match?(/[:.@$]/) && bytes[last] != ":" && name.match?(/\A[a-z_]/)
            helper_span(analysis, name)
          end
        span && { "uri" => uri, "range" => range(analysis, *span) }
      end

      # [line, start_col, end_col] (1-based byte columns, end exclusive) of the name a declaration entry declares:
      # the token of its name when the compiler recorded one (without the colon or quotes), else `:name` found on
      # its first line, else the word that starts the call.
      def name_span(analysis, entry)
        text = analysis.line_text(entry[:line]).b
        if entry[:name_line]
          line = entry[:name_line]
          token = analysis.line_text(line).b
          first = entry[:name_col] - 1
          last = entry[:name_end_col] - 1
          first += 1 if token[first] == ":" || token[first] == '"' || token[first] == "'"
          last -= 1 if token[last - 1] == '"' || token[last - 1] == "'"
          return [line, first + 1, [last, first].max + 1]
        end
        name = entry[:name].to_s
        at = name.empty? ? nil : text.index(/:#{Regexp.escape(name)}(?![A-Za-z0-9_])/n, entry[:col] - 1)
        return [entry[:line], at + 2, at + 2 + name.bytesize] if at

        word = text.byteslice(entry[:col] - 1, text.bytesize)[/\A[A-Za-z_]+/n].to_s
        [entry[:line], entry[:col], entry[:col] + [word.bytesize, 1].max]
      end

      # Byte offsets [first, last) of the identifier at (or just before) byte offset idx, or nil.
      def word_at(bytes, idx)
        idx -= 1 unless word_byte?(bytes[idx]) || idx <= 0
        return nil unless word_byte?(bytes[idx])

        first = idx
        first -= 1 while first.positive? && word_byte?(bytes[first - 1])
        last = idx + 1
        last += 1 while word_byte?(bytes[last])
        [first, last]
      end

      def word_byte?(char) = !char.nil? && char.match?(/[A-Za-z0-9_]/)

      def type_span(analysis, name)
        decl = analysis.types.find { |t| t[:kind] == "declaration" && t[:call] == "params" && t[:name] == name }
        decl ||= analysis.types.find { |t| t[:kind] == "output" && t[:name] == name && output_declaration?(analysis, t) }
        decl && name_span(analysis, decl)
      end

      # An "output" entry is either the declaration (`output :Name do`) or a result(:Name, ...) call.
      def output_declaration?(analysis, entry)
        analysis.line_text(entry[:line]).b.byteslice(entry[:col] - 1, 7).to_s.match?(/\Aoutput\b/)
      end

      def helper_span(analysis, name)
        decl = analysis.types.find { |t| t[:kind] == "helper" && t[:name] == name }
        return nil unless decl

        text = analysis.line_text(decl[:line]).b
        found = text.match(/helper\s+:(#{Regexp.escape(name)})(?![A-Za-z0-9_])/n, decl[:col] - 1)
        found ? [decl[:line], found.begin(1) + 1, found.end(1) + 1] : name_span(analysis, decl)
      end

      def range(analysis, line, first, last)
        text = analysis.line_text(line)
        {
          "start" => { "line" => line - 1, "character" => Position.to_lsp(text, first) },
          "end" => { "line" => line - 1, "character" => Position.to_lsp(text, last) }
        }
      end
    end
  end
end
