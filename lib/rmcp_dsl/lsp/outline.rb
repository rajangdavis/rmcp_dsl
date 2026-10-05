# frozen_string_literal: true

module RmcpDsl
  module Lsp
    # The document outline: an LSP DocumentSymbol[] with the server at the top and, in source order, its params
    # (with their fields), outputs, tools, prompts, resources, helpers and transport as children. Pure; no I/O.
    module Outline
      MODULE = 2
      FIELD = 8
      INTERFACE = 11
      FUNCTION = 12
      CONSTANT = 14
      STRUCT = 23

      SYMBOL_KINDS = {
        "server" => MODULE, "params" => STRUCT, "output" => INTERFACE, "tool" => FUNCTION, "prompt" => FUNCTION,
        "resource" => CONSTANT, "helper" => FUNCTION, "transport" => CONSTANT
      }.freeze
      WITH_FIELDS = %w[params output].freeze

      module_function

      def for(analysis)
        nodes = analysis.types.filter_map do |t|
          call = call_of(analysis, t)
          [call, t] if call && SYMBOL_KINDS.key?(call)
        end
        nodes.sort_by! { |_, t| [t[:line], t[:col]] }
        root = nodes.find { |call, _| call == "server" }
        others = nodes.reject { |pair| pair.equal?(root) }.map { |call, t| symbol(analysis, call, t) }
        return others unless root

        top = symbol(analysis, "server", root[1])
        top["children"] = others
        [top]
      end

      def call_of(analysis, entry)
        case entry[:kind]
        when "declaration" then entry[:call]
        when "helper" then "helper"
        when "output" then Definition.output_declaration?(analysis, entry) ? "output" : nil
        end
      end

      def symbol(analysis, call, entry)
        out = {
          "name" => (entry[:name] || call).to_s,
          "kind" => SYMBOL_KINDS.fetch(call),
          "range" => span(analysis, entry[:line], entry[:col], entry[:end_line], entry[:end_col]),
          "selectionRange" => selection(analysis, entry)
        }
        detail = detail(entry, call)
        out["detail"] = detail unless detail.empty?
        out["children"] = fields(analysis, entry) if WITH_FIELDS.include?(call)
        out
      end

      def detail(entry, call)
        kw = entry[:keywords] || {}
        case call
        when "server" then kw["version"].to_s
        when "tool" then "(#{kw["params"]})#{kw["output"] ? " -> #{kw["output"]}" : ""}"
        when "prompt" then "(#{kw["params"]})"
        when "resource" then kw["uri"].to_s
        when "helper" then entry[:type].to_s
        when "transport" then kw["port"] ? "port #{kw["port"]}" : ""
        else ""
        end
      end

      def fields(analysis, entry)
        inside = analysis.types.select do |t|
          t[:kind] == "field" && ([t[:line], t[:col]] <=> [entry[:line], entry[:col]]) >= 0 &&
            ([t[:end_line], t[:end_col]] <=> [entry[:end_line], entry[:end_col]]) <= 0
        end
        inside.map do |t|
          {
            "name" => t[:name].to_s, "detail" => t[:type].to_s, "kind" => FIELD,
            "range" => span(analysis, t[:line], t[:col], t[:end_line], t[:end_col]), "selectionRange" => selection(analysis, t)
          }
        end
      end

      def selection(analysis, entry)
        line, first, last = Definition.name_span(analysis, entry)
        span(analysis, line, first, line, last)
      end

      def span(analysis, line, col, end_line, end_col)
        {
          "start" => { "line" => line - 1, "character" => Position.to_lsp(analysis.line_text(line), col) },
          "end" => { "line" => end_line - 1, "character" => Position.to_lsp(analysis.line_text(end_line), end_col) }
        }
      end
    end
  end
end
