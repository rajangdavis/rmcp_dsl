# frozen_string_literal: true

module RmcpDsl
  # What the pinned rmcp (RMCP_VERSION) actually provides, and which MCP extension deprecates it.
  #
  # A feature is gated by a server-level declaration (`feature :logging`): declaring it is what puts the
  # corresponding body built-in in scope, advertises the capability, and scopes the `#[allow(deprecated)]`
  # the generated Rust needs. This table is the contract for every gated feature, whether or not a built-in
  # uses it yet (this wave wires `logging`, `roots` and `sampling`).
  #
  #   provided:   true when the pinned rmcp still has the API. If a future rmcp removes one, the next step
  #               is for a declaration to report a backend limitation naming the feature; the DSL syntax
  #               stays the same. Nothing emits that path yet.
  #   deprecated: the SEP that deprecates the feature, or nil. Declaring a deprecated feature is allowed
  #               and emits notice `N-DEPRECATED-FEATURE`; a notice never fails a build.
  #   reference:  the rmcp item or MCP section the entry was checked against.
  #   builtin:    true when this compiler offers a body built-in for the feature.
  #
  # test/test_features.rb keeps this honest by scanning vendor/rmcp-<RMCP_VERSION>/src.
  module Features
    TABLE = {
      logging: { provided: true, deprecated: "SEP-2577", reference: "rmcp::model::LoggingLevel", builtin: true },
      sampling: { provided: true, deprecated: "SEP-2577", reference: "rmcp::model::CreateMessageRequest", builtin: true },
      roots: { provided: true, deprecated: "SEP-2577", reference: "rmcp::model::ListRootsRequest", builtin: true },
      elicitation: { provided: true, deprecated: nil, reference: "rmcp::service::server::create_elicitation" },
      progress: { provided: true, deprecated: nil, reference: "rmcp::service::server::notify_progress" }
    }.freeze

    # Every feature name a `feature :name` declaration accepts.
    NAMES = TABLE.keys.freeze

    module_function

    def get(name) = TABLE[name&.to_sym]

    def names = NAMES

    # The SEP that deprecates the feature, or nil.
    def deprecated(name) = get(name)&.fetch(:deprecated)

    def provided?(name) = !!get(name)&.fetch(:provided)

    # True when declaring the feature provides a body built-in in this compiler.
    def builtin?(name) = !!get(name)&.fetch(:builtin)
  end
end
