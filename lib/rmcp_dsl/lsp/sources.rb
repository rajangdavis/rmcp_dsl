# frozen_string_literal: true

module RmcpDsl
  module Lsp
    # Text the compiler should read instead of the file on disk, by path: an editor's unsaved buffer. The
    # Reader asks here before it parses a file, so the signature of Reader and RmcpDsl.read stays as it is.
    module Sources
      @table = {}

      class << self
        def [](path) = @table[path]

        # Compiles the block with a whole table of documents standing in for their paths — an editor's
        # open buffers, so a compilation of one file reads another (a binding, a rust_file) from its
        # buffer. The table is put back after, so a plain RmcpDsl.read elsewhere reads disk again.
        def with_all(table)
          before = @table
          @table = table
          yield
        ensure
          @table = before
        end

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
