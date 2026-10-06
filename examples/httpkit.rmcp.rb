# typed: true
# httpkit: the same server over streamable HTTP instead of stdio. It listens on 127.0.0.1 and serves MCP at
# /mcp, using rmcp's default session and host settings.
server "httpkit", version: "0.1.0" do
  params :EchoParams do
    field :text, :string, description: "Text to echo"
  end

  tool :echo, params: :EchoParams, description: "Echo the text back", read_only: true do
    body do |text|
      "echo: #{text}"
    end
  end

  transport :http, port: 18765
end
