# frozen_string_literal: true

module RmcpDsl
  # A language server for DSL files, driven by the compiler: diagnostics are the compiler's errors (with their
  # suggestions), hover and inlay hints are the types it inferred. Parts load on first use so each can be
  # built and tested on its own.
  #
  # Positions: the compiler reports 1-based lines and 1-based BYTE columns (Prism). LSP uses 0-based lines and
  # 0-based UTF-16 columns. Everything below Server works in compiler positions; Position converts at the edge.
  module Lsp
    autoload :Sources, File.expand_path("lsp/sources", __dir__)
    autoload :Position, File.expand_path("lsp/position", __dir__)
    autoload :Analysis, File.expand_path("lsp/analysis", __dir__)
    autoload :Server, File.expand_path("lsp/server", __dir__)
    autoload :Hover, File.expand_path("lsp/hover", __dir__)
    autoload :InlayHints, File.expand_path("lsp/inlay_hints", __dir__)
    autoload :Completion, File.expand_path("lsp/completion", __dir__)
    autoload :Definition, File.expand_path("lsp/definition", __dir__)
    autoload :Outline, File.expand_path("lsp/outline", __dir__)
  end
end
