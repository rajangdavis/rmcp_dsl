# expect: `elicit` asks the client for input, which only a tool body can do
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end

  helper :ask, args: [:string], returns: :string do |message|
    elicit(message, schema: { "type" => "object", "properties" => {} }).action
  end

  tool :t, params: :P, description: "x" do
    body do |t|
      ask(t)
    end
  end

  transport :stdio
end
