# expect: elicit takes one argument, the message
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end

  tool :t, params: :P, description: "x" do
    body do |t|
      elicit(schema: { "type" => "object", "properties" => {} }).action
    end
  end

  transport :stdio
end
