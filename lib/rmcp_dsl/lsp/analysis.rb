# frozen_string_literal: true

module RmcpDsl
  module Lsp
    # What the compiler says about one version of one document. Nothing is cached across versions: a new
    # Analysis is built per change (compiling a DSL file takes milliseconds). Positions are the compiler's
    # (1-based line, 1-based byte column); see Lsp.
    #
    # A use_dsl fragment is compiled through the server file that includes it (Fragments.root_for), and a root's
    # compile can stop in one of its fragments, so an error is sorted by the file it names: this document's own
    # go to `diagnostics`, another file's to `elsewhere`, which the server publishes to that file.
    class Analysis
      # message: text without the "FILE:LINE:COL:" prefix. end_col is 1-based exclusive, on the same line.
      # severity is LSP's: 1 an error, 3 information.
      Diagnostic = Struct.new(:line, :col, :end_col, :message, :suggestions, :severity, keyword_init: true) do
        def initialize(**kw)
          super
          self.severity ||= 1
        end
      end

      ERROR_ROW = /\A(.+?):(\d+):(\d+): (.*)\z/

      attr_reader :path, :text, :lines, :types, :all_types, :diagnostics, :elsewhere, :files, :root, :records

      # `types` entries are hashes with symbol keys: line, col, end_line, end_col, kind ("parameter", "local",
      # "expression", "field", "helper" or "output"), type (a display string like "T.nilable(String)") and
      # optionally name. They cover everything the compiler typed before it stopped, so hover keeps working
      # above a mistake. `all_types` are the same for every DSL file of the compile, each with its :file.
      def initialize(path, text)
        @path = path
        @real = RmcpDsl.canon(path)
        @text = text
        @lines = text.split("\n", -1)
        @diagnostics = []
        @elsewhere = {} # another file's absolute path => its Diagnostics, from this compile
        @files = [] # the `file` declarations of a file that compiled, for go-to-definition and entry completion
        @records = {} # "Rows::Row" => the record's CompositeTypes::Opaque::Entry, from the bindings this compile loaded
        @ok = false
        collector = TypeNames::Collector.new(path)
        @root = Sources.with(path, text) { Fragments.fragment?(text) ? Fragments.root_for(path) : path }
        if @root
          compile(collector)
        else
          @diagnostics = [Diagnostic.new(line: 1, col: 1, end_col: 2, severity: 3, suggestions: [],
                                         message: "no file says use_dsl for this fragment, so it is not checked; " \
                                                  "add `use_dsl` for it to a server file in this folder or one above")]
        end
        @types = collector.entries
        @all_types = collector.all_entries
      end

      # Whether the compile succeeded.
      def ok? = @ok

      def line_text(line, file = nil) = lines_of(file)[line - 1].to_s

      # The lines of a file of this compile: this document's own, or another's from its buffer or disk.
      def lines_of(file)
        return @lines if file.nil? || file == @real

        (@other_lines ||= {})[file] ||= (Sources[file] || File.read(file, encoding: "UTF-8")).split("\n", -1)
      rescue SystemCallError
        []
      end

      # Entries containing a position, narrowest first. line and byte_col are 1-based.
      def types_at(line, byte_col)
        found = @types.select do |t|
          (line > t[:line] || (line == t[:line] && byte_col >= t[:col])) &&
            (line < t[:end_line] || (line == t[:end_line] && byte_col < t[:end_col]))
        end
        found.sort_by { |t| [t[:end_line] - t[:line], t[:end_col] - t[:col]] }
      end

      private

      def compile(collector)
        ir = Sources.with(@path, @text) { Reader.new(@root, types: collector).read } # the editor's text, not the file on disk
        @files = ir["files"].to_a
        @ok = true
      rescue CompileError => e
        sort_errors(e)
      rescue StandardError => e # a compiler bug must not take the editor down
        @diagnostics = [Diagnostic.new(line: 1, col: 1, end_col: 2, message: "rmcp_dsl internal error: #{e.class}: #{e.message}", suggestions: [])]
      ensure
        # The bindings are loaded before any body, so a body still being typed sees its records' fields.
        @records = CompositeTypes::Opaque.types.reject { |t| t.fields.to_a.empty? }.to_h { |t| [t.name, t] }
      end

      # CompileError#message is "FILE:LINE:COL: text", one per line for syntax errors; a line that does not start
      # with that prefix continues the previous message. Suggestions belong to the last (only) semantic error.
      def sort_errors(error)
        rows = []
        error.message.to_s.split("\n").each do |row|
          if (m = row.match(ERROR_ROW))
            rows << { file: RmcpDsl.canon(m[1]), line: m[2].to_i, col: m[3].to_i, message: m[4] }
          elsif rows.any?
            rows.last[:message] += "\n#{row}"
          else
            rows << { file: @real, line: 1, col: 1, message: row }
          end
        end
        rows = [{ file: @real, line: 1, col: 1, message: error.message.to_s }] if rows.empty?
        rows.each_with_index do |d, i|
          diag = Diagnostic.new(line: d[:line], col: d[:col], end_col: token_end(d[:file], d[:line], d[:col]), message: d[:message],
                                suggestions: i == rows.size - 1 ? error.suggestions : [])
          d[:file] == @real ? @diagnostics << diag : (@elsewhere[d[:file]] ||= []) << diag
        end
        point_at_elsewhere(rows.first) if @diagnostics.empty?
      end

      # The compile stopped in another file. A root says so on the use_dsl line that brings that file in (the
      # first line when it comes in through a nested fragment); a fragment says which file stopped its check.
      def point_at_elsewhere(first)
        where = "#{first[:file]}:#{first[:line]}"
        if @root == @path
          line = use_dsl_line(first[:file]) || 1
          @diagnostics << Diagnostic.new(line: line, col: 1, end_col: line_text(line).bytesize + 1, suggestions: [],
                                         message: "#{where}: #{first[:message]}")
        else
          @diagnostics << Diagnostic.new(line: 1, col: 1, end_col: line_text(1).bytesize + 1, severity: 3, suggestions: [],
                                         message: "not checked: #{@root} stops at #{where}: #{first[:message]}")
        end
      end

      def use_dsl_line(file)
        dir = File.dirname(@real)
        idx = @lines.index do |l|
          (m = l.match(/\A\s*use_dsl\s+"([^"]+)"/)) && RmcpDsl.canon(File.expand_path(m[1], dir)) == file
        end
        idx && idx + 1
      end

      # The error position is the start of the offending node; underline its first token, or the rest of the
      # line when that is not a word.
      def token_end(file, line, col)
        text = line_text(line, file)
        rest = text.byteslice(col - 1, text.bytesize).to_s
        word = rest[/\A[A-Za-z0-9_?!:@$.]+/]
        word ||= rest.rstrip
        col + [word.bytesize, 1].max
      end
    end

    # A fragment (a file whose one top-level call is `fragment`) is checked through the server file that
    # includes it. Its root is the first *.rmcp.rb, in the fragment's folder or one above it (up to MAX_UP, and
    # not above a folder holding .git), that is not itself a fragment and says use_dsl for it, directly or
    # through other fragments. Buffers stand in for disk (Sources), so an unsaved use_dsl line counts.
    module Fragments
      MAX_UP = 4
      HEAD = /\A(?:[ \t]*(?:#[^\n]*)?\n)*[ \t]*fragment\s*(?:do\b|\{)/

      module_function

      def fragment?(text) = text.match?(HEAD)

      def root_for(path)
        want = RmcpDsl.canon(path)
        dir = File.dirname(want)
        (MAX_UP + 1).times do
          Dir.glob(File.join(dir, "*.rmcp.rb")).sort.each do |cand|
            next if RmcpDsl.canon(cand) == want

            text = read(cand)
            return cand if text && text.include?("use_dsl") && !fragment?(text) && includes?(cand, want, {})
          end
          up = File.dirname(dir)
          break if File.exist?(File.join(dir, ".git")) || up == dir

          dir = up
        end
        nil
      end

      def includes?(file, want, seen)
        return false if seen[file]

        seen[file] = true
        text = read(file) or return false
        text.scan(/^[ \t]*use_dsl\s+"([^"]+)"/).flatten.any? do |rel|
          target = RmcpDsl.canon(File.expand_path(rel, File.dirname(file)))
          target == want || includes?(target, want, seen)
        end
      end

      def read(file)
        Sources[file] || File.read(file, encoding: "UTF-8")
      rescue SystemCallError
        nil
      end
    end
  end
end
