# expect: MCP does not complete tool arguments
server "t", version: "0.1.0" do
  helper :choices, args: [:string], returns: :string_list do |typed|
    ["a"].select { |v| v.start_with?(typed) }
  end

  params :P do
    field :topic, :string, complete: :choices
  end

  tool :x, params: :P, description: "d" do
    body do |topic|
      topic
    end
  end

  transport :stdio
end
