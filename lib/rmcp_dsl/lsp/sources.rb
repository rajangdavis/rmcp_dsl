# frozen_string_literal: true

module RmcpDsl
  module Lsp
    # Text the compiler should read instead of the file on disk, by path: an editor's unsaved buffer. The
    # Reader asks here before it parses a file, so the signature of Reader and RmcpDsl.read stays as it is.
    module Sources
      @table = {}

      class << self
        def [](path) = @table[path]

        # Compiles the block with `text` standing in for `path`, then puts things back.
        def with(path, text)
          before = @table[path]
          @table[path] = text
          yield
        ensure
          before.nil? ? @table.delete(path) : @table[path] = before
        end
      end
    end
  end
end
