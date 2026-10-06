# expect: `verbose` is not an MCP logging level
server "t", version: "0.1.0" do
  feature :logging
  params :P do
    field :message, :string
  end

  tool :log_it, params: :P, description: "d" do
    body do |message|
      log(:verbose, message)
      "ok"
    end
  end

  transport :stdio
end
