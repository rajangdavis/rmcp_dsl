# frozen_string_literal: true

require "json"

module RmcpDsl
  module Lsp
    # Language Server Protocol over stdio: Content-Length framed JSON-RPC 2.0, UTF-8. Documents are compiled
    # with Analysis on open and change; hover, inlay hints and completion are delegated to collaborators
    # (Hover, InlayHints, Completion unless injected). Positions arrive as 0-based line and UTF-16 column.
    class Server
      PARSE_ERROR = -32_700
      METHOD_NOT_FOUND = -32_601
      INTERNAL_ERROR = -32_603

      Document = Struct.new(:text, :version, :analysis)

      # Standard requests a client sends whatever the capabilities say (references, formatting, rename, ...). They are
      # not implemented here, and "nothing found" is a better answer than a method-not-found error.
      EMPTY_ANSWERS_RESULT = {
        "textDocument/documentLink" => [], "textDocument/documentHighlight" => [],
        "textDocument/foldingRange" => [], "textDocument/codeLens" => [], "textDocument/references" => [],
        "textDocument/declaration" => nil, "textDocument/typeDefinition" => nil,
        "textDocument/implementation" => nil, "textDocument/signatureHelp" => nil, "textDocument/formatting" => nil,
        "textDocument/rangeFormatting" => nil, "textDocument/onTypeFormatting" => nil, "textDocument/rename" => nil,
        "textDocument/prepareRename" => nil, "textDocument/semanticTokens/full" => nil, "workspace/symbol" => []
      }.freeze
      EMPTY_ANSWERS = EMPTY_ANSWERS_RESULT.keys.freeze

      def initialize(input, output, hover: nil, inlay_hints: nil, completion: nil)
        @input = input
        @output = output
        @hover = hover
        @inlay_hints = inlay_hints
        @completion = completion
        @documents = {}
        @shutdown = false
        @exit = false
        @input.binmode if @input.respond_to?(:binmode)
        @output.binmode if @output.respond_to?(:binmode)
      end

      # Reads messages until `exit` or end of input. With RMCP_DSL_LSP_LOG=FILE set, everything received and sent is
      # appended to FILE, with start and stop lines and any crash, so a client that cannot talk to the server can be
      # debugged. (No file at all means the command never ran this code.)
      def run
        log("==", "start pid=#{Process.pid} ruby=#{RUBY_VERSION} cwd=#{Dir.pwd} version=#{RmcpDsl::VERSION}")
        until @exit
          raw = read_frame
          break if raw.nil?

          log("<-", raw)
          begin
            message = JSON.parse(raw)
          rescue JSON::ParserError => e
            report("bad JSON: #{e.message}")
            send_message(jsonrpc: "2.0", id: nil, error: { code: PARSE_ERROR, message: "parse error" })
            next
          end
          handle(message)
        end
        log("==", @exit ? "stop: exit received" : "stop: input closed")
      rescue Exception => e # rubocop:disable Lint/RescueException -- logged, then re-raised
        log("!!", "crash #{e.class}: #{e.message}\n#{e.backtrace.to_a.first(15).join("\n")}")
        raise
      end

      # One decoded message. Requests are answered, notifications acted on; anything sent goes to the output.
      def handle(message)
        return unless message.is_a?(Hash)

        method = message["method"]
        return if method.nil? # a response to us; we send no requests

        params = message["params"] || {}
        if message.key?("id")
          respond(message["id"], method, params)
        else
          notify(method, params)
        end
      rescue StandardError => e
        report("#{method}: #{e.class}: #{e.message}")
        send_message(jsonrpc: "2.0", id: message["id"], error: { code: INTERNAL_ERROR, message: e.message }) if message.key?("id")
      end

      def uri_to_path(uri)
        rest = uri.sub(%r{\Afile://[^/]*}, "")
        rest.gsub(/(?:%\h\h)+/) { |m| [m.delete("%")].pack("H*").force_encoding(Encoding::UTF_8) }
      end

      private

      def read_frame
        length = nil
        loop do
          line = @input.gets("\n")
          return nil if line.nil?

          line = line.chomp
          break if line.empty? && length
          next if line.empty?

          length = Regexp.last_match(1).to_i if line =~ /\AContent-Length:\s*(\d+)/i
        end
        body = @input.read(length)
        body&.force_encoding(Encoding::UTF_8)
      end

      def send_message(hash)
        body = JSON.generate(hash)
        log("->", body)
        @output.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
        @output.flush
      end

      # A problem the server survives: to stderr (never stdout, which is the protocol) and to the log.
      def report(text)
        warn "rmcp_dsl lsp: #{text}"
        log("!!", text)
      end

      def log(direction, text)
        path = ENV["RMCP_DSL_LSP_LOG"]
        return if path.nil? || path.empty?

        File.open(path, "a") { |f| f.puts("#{Time.now.strftime('%H:%M:%S.%L')} #{direction} #{text}") }
      rescue SystemCallError
        nil
      end

      def respond(id, method, params)
        result =
          case method
          when "initialize" then initialize_result
          when "shutdown" then (@shutdown = true) && nil
          when "textDocument/hover" then at_position(params, @hover, :Hover, :at, nil)
          when "textDocument/definition" then definition(params)
          when "textDocument/documentSymbol" then document_symbols(params)
          when "textDocument/completion" then completion(params)
          when "textDocument/inlayHint" then inlay_hints(params)
          when "textDocument/codeAction" then code_actions(params)
          when *EMPTY_ANSWERS then EMPTY_ANSWERS_RESULT.fetch(method, nil)
          else
            send_message(jsonrpc: "2.0", id: id, error: { code: METHOD_NOT_FOUND, message: "method not found: #{method}" })
            return
          end
        send_message(jsonrpc: "2.0", id: id, result: result)
      end

      def notify(method, params)
        case method
        when "exit" then @exit = true
        when "textDocument/didOpen"
          doc = params["textDocument"]
          store(doc["uri"], doc["text"], doc["version"])
        when "textDocument/didChange"
          changes = params["contentChanges"] || []
          store(params.dig("textDocument", "uri"), changes.last["text"], params.dig("textDocument", "version")) unless changes.empty?
        when "textDocument/didSave"
          text = params["text"]
          store(params.dig("textDocument", "uri"), text, nil) if text
        when "textDocument/didClose"
          uri = params.dig("textDocument", "uri")
          @documents.delete(uri)
          publish(uri, [], nil)
        end
      end

      def initialize_result
        {
          capabilities: {
            textDocumentSync: { openClose: true, change: 1, save: { includeText: false } },
            hoverProvider: true,
            definitionProvider: true,
            documentSymbolProvider: true,
            inlayHintProvider: true,
            completionProvider: { triggerCharacters: [".", ":", "|", " "] },
            codeActionProvider: { codeActionKinds: ["quickfix"] }
          },
          serverInfo: { name: "rmcp_dsl", version: RmcpDsl::VERSION }
        }
      end

      def store(uri, text, version)
        analysis = Analysis.new(uri_to_path(uri), text)
        @documents[uri] = Document.new(text, version, analysis)
        publish(uri, analysis.diagnostics.map { |d| lsp_diagnostic(analysis, d) }, version)
      end

      def publish(uri, diagnostics, version)
        params = { uri: uri, diagnostics: diagnostics }
        params[:version] = version if version
        send_message(jsonrpc: "2.0", method: "textDocument/publishDiagnostics", params: params)
      end

      def lsp_diagnostic(analysis, diag)
        text = analysis.line_text(diag.line)
        {
          range: {
            start: { line: diag.line - 1, character: Position.to_lsp(text, diag.col) },
            end: { line: diag.line - 1, character: Position.to_lsp(text, diag.end_col) }
          },
          severity: 1,
          source: "rmcp_dsl",
          message: diag.message,
          data: { suggestions: diag.suggestions }
        }
      end

      # The analysis for the open version, or a fresh one from disk for a document that is not open.
      def analysis_for(uri)
        doc = @documents[uri]
        return doc.analysis if doc

        path = uri_to_path(uri)
        Analysis.new(path, File.read(path, encoding: "UTF-8"))
      rescue SystemCallError
        nil
      end

      def collaborator(injected, name)
        injected || Lsp.const_get(name)
      rescue LoadError, NameError
        nil
      end

      def guarded(fallback)
        yield
      rescue StandardError, LoadError, NotImplementedError => e
        report("#{e.class}: #{e.message}")
        fallback
      end

      def at_position(params, injected, name, meth, fallback)
        mod = collaborator(injected, name)
        analysis = analysis_for(params.dig("textDocument", "uri"))
        return fallback unless mod && analysis

        guarded(fallback) { mod.public_send(meth, analysis, params["position"]["line"], params["position"]["character"]) }
      end

      def definition(params)
        uri = params.dig("textDocument", "uri")
        mod = collaborator(nil, :Definition)
        analysis = analysis_for(uri)
        return nil unless mod && analysis

        guarded(nil) { mod.at(analysis, params["position"]["line"], params["position"]["character"], uri) }
      end

      def document_symbols(params)
        mod = collaborator(nil, :Outline)
        analysis = analysis_for(params.dig("textDocument", "uri"))
        return [] unless mod && analysis

        guarded([]) { mod.for(analysis) } || []
      end

      def completion(params)
        items = at_position(params, @completion, :Completion, :at, [])
        { isIncomplete: false, items: items || [] }
      end

      def inlay_hints(params)
        mod = collaborator(@inlay_hints, :InlayHints)
        analysis = analysis_for(params.dig("textDocument", "uri"))
        return [] unless mod && analysis

        range = params["range"]
        guarded([]) { mod.for(analysis, range["start"]["line"], range["end"]["line"]) } || []
      end

      def code_actions(params)
        uri = params.dig("textDocument", "uri")
        analysis = analysis_for(uri)
        return [] unless analysis

        diagnostics = params.dig("context", "diagnostics") || []
        diagnostics.flat_map { |diag| quick_fixes(uri, analysis, diag) }
      end

      def quick_fixes(uri, analysis, diag)
        suggestions = Array(diag.dig("data", "suggestions"))
        word = diag["message"].to_s[/`([^`]+)`/, 1]
        return [] if suggestions.empty? || word.nil?

        line0 = diag.dig("range", "start", "line")
        text = analysis.line_text(line0 + 1)
        from = Position.from_lsp(text, diag.dig("range", "start", "character")) - 1
        found = word_span(text, word, from) || word_span(text, word, 0)
        return [] unless found

        range = {
          start: { line: line0, character: Position.to_lsp(text, found[0] + 1) },
          end: { line: line0, character: Position.to_lsp(text, found[1] + 1) }
        }
        suggestions.map do |new|
          {
            title: "Replace `#{word}` with `#{new}`",
            kind: "quickfix",
            diagnostics: [diag],
            edit: { changes: { uri => [{ range: range, newText: new }] } }
          }
        end
      end

      # [start, end) byte offsets of the first whole-word occurrence of word at or after byte offset from.
      def word_span(text, word, from)
        re = /(?<![A-Za-z0-9_])#{Regexp.escape(word)}(?![A-Za-z0-9_])/
        m = text.match(re, text.byteslice(0, from).to_s.length)
        pos = m && text[0, m.begin(0)].bytesize
        pos && [pos, pos + word.bytesize]
      end
    end
  end
end
