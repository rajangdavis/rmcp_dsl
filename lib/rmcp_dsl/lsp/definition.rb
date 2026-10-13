# frozen_string_literal: true

module RmcpDsl
  module Lsp
    # Go to definition: from a name used somewhere to the token that declares it. Pure; no I/O.
    #   - a CamelCase symbol (params: :Name, output: :Name, field :x, :Name, result(:Name, ...)) -> the name token of
    #     the params or output declaration
    #   - a helper call, name(args) -> the helper's name in `helper :name`
    #   - the entry in entry(:file, :name) or entry_args(:file, :name, ...) -> its `def` line in that file
    #   - the path in use_dsl "dsl/x.rmcp.rb" -> that file
    # A params, output or helper declared in a use_dsl fragment is found in that file. Anything else, and a name
    # nothing declares, answers nil.
    module Definition
      module_function

      # line0 and utf16_col are LSP's. Returns an LSP Location {"uri", "range"}, or nil.
      def at(analysis, line0, utf16_col, uri)
        line = line0 + 1
        text = analysis.line_text(line)
        bytes = text.b
        col = Position.from_lsp(text, utf16_col) - 1
        included = use_dsl_location(analysis, bytes, col)
        return included if included

        word = word_at(bytes, col)
        return nil unless word

        first, last = word
        name = bytes[first...last].force_encoding(Encoding::UTF_8)
        before = first.positive? ? bytes[first - 1] : ""
        entry = entry_location(analysis, bytes[0...first].force_encoding(Encoding::UTF_8), name)
        return entry if entry

        record = record_location(analysis, line, bytes, first, last, name, before)
        return record if record

        found =
          if before == ":" && !(first > 1 && bytes[first - 2] == ":") && name.match?(/\A[A-Z]/)
            type_span(analysis, name)
          elsif !before.match?(/[:.@$]/) && bytes[last] != ":" && name.match?(/\A[a-z_]/)
            helper_span(analysis, name)
          end
        return nil unless found

        file, *span = found
        own = file.nil? || file == RmcpDsl.canon(analysis.path)
        { "uri" => own ? uri : file_uri(file), "range" => range(analysis, *span, file) }
      end

      # A binding record (docs/specs/typed_record.md): a field read after a dot (row.text, rows.first&.href) whose
      # receiver the compiler typed as a record -> that `field` line in the binding; the record's name (Rows::Row)
      # -> its `class` line.
      def record_location(analysis, line, bytes, first, last, name, before)
        if before == "." && name.match?(/\A[a-z_]/)
          stop = first - 1 # the dot, 0-based; the receiver ends before it (and before a `&` of `&.`)
          stop -= 1 if stop.positive? && bytes[stop - 1] == "&"
          recv = analysis.types_at(line, stop).first or return nil
          rec = analysis.records[recv[:type].to_s[/[A-Z]\w*::[A-Z]\w*/]] or return nil
          field = rec.fields.find { |n, _, _| n == name } or return nil
          at_line = field[2]
        elsif name.match?(/\A[A-Z]/) && (q = bytes[0...last].force_encoding(Encoding::UTF_8)[/([A-Z]\w*::[A-Z]\w*)\z/, 1])
          rec = analysis.records[q] or return nil
          at_line = rec.line
        else
          return nil
        end
        at = { "line" => at_line - 1, "character" => 0 }
        { "uri" => file_uri(rec.path), "range" => { "start" => at, "end" => at } }
      end

      # The file a use_dsl path names, when the position is inside its quotes; nil otherwise.
      def use_dsl_location(analysis, bytes, col)
        m = bytes.match(/\A\s*use_dsl\s+"([^"]+)"/n) or return nil
        return nil unless col.between?(m.begin(1), m.end(1))

        path = File.expand_path(m[1].force_encoding(Encoding::UTF_8), File.dirname(analysis.path))
        return nil unless File.file?(path)

        at = { "line" => 0, "character" => 0 }
        { "uri" => file_uri(RmcpDsl.canon(path)), "range" => { "start" => at, "end" => at } }
      end

      # [line, start_col, end_col] (1-based byte columns, end exclusive) of the name a declaration entry declares:
      # the token of its name when the compiler recorded one (without the colon or quotes), else `:name` found on
      # its first line, else the word that starts the call.
      def name_span(analysis, entry)
        text = analysis.line_text(entry[:line], entry[:file]).b
        if entry[:name_line]
          line = entry[:name_line]
          token = analysis.line_text(line, entry[:file]).b
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

      # [file, line, first, last] of the params or output declaring `name`, in any file of the compile.
      def type_span(analysis, name)
        decl = analysis.all_types.find { |t| t[:kind] == "declaration" && t[:call] == "params" && t[:name] == name }
        decl ||= analysis.all_types.find { |t| t[:kind] == "output" && t[:name] == name && output_declaration?(analysis, t) }
        decl && [decl[:file], *name_span(analysis, decl)]
      end

      # An "output" entry is either the declaration (`output :Name do`) or a result(:Name, ...) call.
      def output_declaration?(analysis, entry)
        analysis.line_text(entry[:line], entry[:file]).b.byteslice(entry[:col] - 1, 7).to_s.match?(/\Aoutput\b/)
      end

      # [file, line, first, last] of the helper's name in `helper :name`, in any file of the compile.
      def helper_span(analysis, name)
        decl = analysis.all_types.find { |t| t[:kind] == "helper" && t[:name] == name }
        return nil unless decl

        text = analysis.line_text(decl[:line], decl[:file]).b
        found = text.match(/helper\s+:(#{Regexp.escape(name)})(?![A-Za-z0-9_])/n, decl[:col] - 1)
        [decl[:file], *(found ? [decl[:line], found.begin(1) + 1, found.end(1) + 1] : name_span(analysis, decl))]
      end

      # The entry name in entry(:file, :name) or entry_args(:file, :name, ...) -> the `def` line in that file.
      def entry_location(analysis, before, name)
        m = before.match(/\bentry(?:_args)?\(\s*:(\w+)\s*,\s*:\z/) or return nil
        file = analysis.files.find { |f| f["name"] == m[1] } or return nil
        sig = file["sigs"][name] or return nil
        at = { "line" => sig["line"] - 1, "character" => 0 }
        { "uri" => file_uri(file["real"]), "range" => { "start" => at, "end" => at } }
      end

      def file_uri(path) = "file://#{path.b.gsub(%r{[^A-Za-z0-9\-._~/]}n) { |c| format('%%%02X', c.ord) }}"

      def range(analysis, line, first, last, file = nil)
        text = analysis.line_text(line, file)
        {
          "start" => { "line" => line - 1, "character" => Position.to_lsp(text, first) },
          "end" => { "line" => line - 1, "character" => Position.to_lsp(text, last) }
        }
      end
    end
  end
end
