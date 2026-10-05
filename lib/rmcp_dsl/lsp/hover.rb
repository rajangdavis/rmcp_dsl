# frozen_string_literal: true

module RmcpDsl
  module Lsp
    # Hover: the type the compiler inferred at a position, as an LSP Hover. Pure; no I/O.
    module Hover
      KIND_TEXT = {
        "parameter" => "block parameter",
        "local" => "local variable",
        "field" => "field",
        "helper" => "helper",
        "output" => "output",
        "expression" => "expression"
      }.freeze

      module_function

      # line0 and utf16_col are LSP's (0-based, UTF-16). Returns nil, or {"contents" => ..., "range" => ...}.
      def at(analysis, line0, utf16_col)
        line = line0 + 1
        col = Position.from_lsp(analysis.line_text(line), utf16_col)
        declared = declaration_hover(analysis, line, col)
        return declared if declared

        entry = pick(analysis.types_at(line, col))
        return nil unless entry

        {
          "contents" => { "kind" => "markdown", "value" => render(entry) },
          "range" => range(analysis, entry)
        }
      end

      # types_at is narrowest first. The narrowest span wins; among entries with that very span (a call and
      # its receiver are different spans, so hovering either picks its own) the one with a name wins.
      def pick(hits)
        # A declaration entry spans its whole block, so it must not answer for everything inside it; declaration_hover
        # answers for its call-name token, its name token and its keyword labels instead.
        hits = hits.reject { |t| t[:kind] == "declaration" }
        return nil if hits.empty?

        first = hits.first
        same = hits.select { |t| [t[:line], t[:col], t[:end_line], t[:end_col]] == [first[:line], first[:col], first[:end_line], first[:end_col]] }
        same.find { |t| t[:name] } || first
      end

      TOOL_FLAGS = %w[read_only destructive idempotent open_world].freeze
      # The keywords worth showing for a call that has no summary of its own.
      SHOWN_KEYWORDS = { "resource" => %w[uri], "server" => %w[version] }.freeze

      # Hover for a DSL call (`tool`, `params`, ...): from its call-name token or its name token, a summary and the
      # call's documentation; from a keyword label on the call's own lines (not in a nested block), that keyword's
      # documentation with its value. Returns a Hover, or nil.
      def declaration_hover(analysis, line, col)
        decls = analysis.types_at(line, col).select { |t| t[:kind] == "declaration" }
        decls.each do |entry|
          token = declaration_token(entry, line, col)
          next unless token

          return hover_for(analysis, declaration_markdown(analysis, entry), line, token[0], token[1])
        end
        entry = decls.first
        found = entry && keyword_label(analysis, entry, line, col)
        return nil unless found

        word, first, last = found
        doc = Docs.keyword(entry[:call], word)
        return nil unless doc

        value = entry[:keywords][word]
        value = "[#{value.join(", ")}]" if value.is_a?(Array)
        hover_for(analysis, "```ruby\n#{word}: #{value}\n```\n#{doc}", line, first, last)
      end

      # [first, last) columns when the position is on the call name or the name token of the declaration, else nil.
      def declaration_token(entry, line, col)
        width = entry[:call].to_s.bytesize
        return [entry[:col], entry[:col] + width] if line == entry[:line] && col >= entry[:col] && col < entry[:col] + width
        return [entry[:name_col], entry[:name_end_col]] if entry[:name_line] == line && col >= entry[:name_col] && col < entry[:name_end_col]

        nil
      end

      def hover_for(analysis, markdown, line, first, last)
        text = analysis.line_text(line)
        {
          "contents" => { "kind" => "markdown", "value" => markdown },
          "range" => {
            "start" => { "line" => line - 1, "character" => Position.to_lsp(text, first) },
            "end" => { "line" => line - 1, "character" => Position.to_lsp(text, last) }
          }
        }
      end

      def declaration_markdown(analysis, entry)
        call = entry[:call].to_s
        name = entry[:name]
        kw = entry[:keywords] || {}
        code =
          case call
          when "params" then ["params #{name}", *field_lines(analysis, entry)]
          when "tool" then tool_lines(name, kw)
          when "prompt" then ["prompt #{name}(#{kw["params"]})"]
          else [[call, name].compact.join(" ") + shown_keywords(call, kw)]
          end
        doc = Docs.call(call)
        "```ruby\n#{code.join("\n")}\n```#{doc ? "\n#{doc}" : ""}"
      end

      def tool_lines(name, kw)
        head = "tool #{name}(#{kw["params"]})#{kw["output"] ? " -> #{kw["output"]}" : ""}"
        flags = TOOL_FLAGS.filter_map { |f| kw.key?(f) ? (kw[f] == "true" ? f : "#{f}: #{kw[f]}") : nil }
        flags.empty? ? [head] : [head, flags.join(", ")]
      end

      def shown_keywords(call, kw)
        shown = SHOWN_KEYWORDS.fetch(call, kw.keys)
        shown.filter_map { |k| ", #{k}: #{short(kw[k])}" if kw.key?(k) }.join
      end

      def short(value)
        text = value.is_a?(Array) ? "[#{value.join(", ")}]" : value.to_s
        text.length > 40 ? "#{text[0, 37]}..." : text
      end

      def field_lines(analysis, entry)
        analysis.types.filter_map do |t|
          next unless t[:kind] == "field" && ([t[:line], t[:col]] <=> [entry[:line], entry[:col]]) >= 0 &&
                      ([t[:end_line], t[:end_col]] <=> [entry[:end_line], entry[:end_col]]) <= 0

          "  #{t[:name]}: #{t[:type]}"
        end
      end

      # [keyword, first, last] when the position is on a `keyword:` label of the entry's call, on the lines before
      # its block starts, outside any string; else nil.
      def keyword_label(analysis, entry, line, col)
        return nil unless line.between?(entry[:line], header_end(analysis, entry))

        bytes = analysis.line_text(line).b
        idx = col - 1
        return nil unless word_byte?(bytes[idx])

        first = idx
        first -= 1 while first.positive? && word_byte?(bytes[first - 1])
        last = idx
        last += 1 while word_byte?(bytes[last + 1])
        last += 1
        word = bytes[first...last].force_encoding(Encoding::UTF_8)
        return nil unless bytes[last] == ":" && bytes[last + 1] != ":" && !(first.positive? && bytes[first - 1] == ":")
        return nil unless entry[:keywords]&.key?(word)
        return nil if bytes[0...first].scan(/(?<!\\)"/n).size.odd?

        [word, first + 1, last + 1]
      end

      def word_byte?(char) = !char.nil? && char.match?(/[A-Za-z0-9_]/)

      # The last line of the call before its block: the first line that ends in `do` (or `do |x|`), else the call's end.
      def header_end(analysis, entry)
        (entry[:line]..entry[:end_line]).find { |n| analysis.line_text(n).match?(/\bdo\s*(\|[^|]*\|)?\s*\z/) } || entry[:end_line]
      end

      def render(entry)
        type = entry[:type].to_s
        name = entry[:name]
        code =
          case entry[:kind]
          when "parameter", "local" then name ? "#{name}: #{type}" : type
          when "helper" then name ? "#{name} #{type}" : type
          when "field" then name ? "field :#{name} -> #{type}" : "field -> #{type}"
          when "output" then "Output #{name || type}"
          else type
          end
        "```ruby\n#{code}\n```\n#{KIND_TEXT.fetch(entry[:kind], entry[:kind].to_s)}"
      end

      def range(analysis, entry)
        {
          "start" => { "line" => entry[:line] - 1, "character" => Position.to_lsp(analysis.line_text(entry[:line]), entry[:col]) },
          "end" => { "line" => entry[:end_line] - 1, "character" => Position.to_lsp(analysis.line_text(entry[:end_line]), entry[:end_col]) }
        }
      end
    end
  end
end
