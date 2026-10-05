# frozen_string_literal: true

module RmcpDsl
  module Lsp
    # Inlay hints: the inferred type after a block parameter at its declaration (`|email, level|`) and after a
    # local at its assignment. Reads get none. Pure; no I/O.
    module InlayHints
      PARAM_LIST = /(?:\bdo|\{)\s*\|([^|]*)\|/n
      ASSIGNMENT = /\A\s*=(?![=~>])/n

      module_function

      # start_line0 and end_line0 are LSP lines, inclusive.
      def for(analysis, start_line0, end_line0)
        seen = {}
        analysis.types.each_with_object([]) do |t, out|
          next unless %w[parameter local].include?(t[:kind])
          next unless t[:line] == t[:end_line] && (start_line0 + 1..end_line0 + 1).cover?(t[:line])
          next unless declaration?(analysis.line_text(t[:line]), t)

          key = [t[:line], t[:end_col]]
          next if seen[key]

          seen[key] = true
          out << {
            "position" => { "line" => t[:line] - 1, "character" => Position.to_lsp(analysis.line_text(t[:line]), t[:end_col]) },
            "label" => ": #{t[:type]}",
            "kind" => 1,
            "paddingLeft" => false
          }
        end
      end

      def declaration?(line_text, entry)
        bytes = line_text.b
        if entry[:kind] == "parameter"
          offset = 0
          while (m = PARAM_LIST.match(bytes, offset))
            from = m.begin(1) + 1 # 1-based byte column of the first byte between the pipes
            return true if entry[:col] >= from && entry[:end_col] <= from + m[1].to_s.bytesize

            offset = m.end(0)
          end
          false
        else
          ASSIGNMENT.match?(bytes.byteslice(entry[:end_col] - 1, bytes.bytesize).to_s)
        end
      end
    end
  end
end
