# typed: true
# rootskit: a server that declares `feature :roots` (deprecated by SEP-2577) and asks the client for its
# roots from a tool body. `roots()` is a server-to-client request (`roots/list`): the body reads each root's
# uri and nil-able name. Only a tool body may call it, and declaring the feature is what puts it in scope.
server "rootskit", version: "0.1.0",
       instructions: "Call `summarize_roots` to summarize the roots the client declared." do
  feature :roots

  params :RootsParams do
    field :tag, :string, description: "A label to prefix each root in the summary"
  end

  tool :summarize_roots, params: :RootsParams, description: "Summarize the client's roots",
                         read_only: true, open_world: false do
    body do |tag|
      rs = roots()
      "count=#{rs.length} " + rs.map { |root| "#{tag}:#{root.uri}=#{root.name || "-"}" }.join(", ")
    end
  end

  transport :stdio
end
