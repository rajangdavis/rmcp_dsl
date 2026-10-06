# expect: must say `"type" => "object"`
server "refuse", version: "0.1.0" do
  params :P do
    field :q, :string
    field :n, :i64, optional: true
  end
  tool :t, params: :P, description: "x", input_schema: { "type" => "array" } do
    body do |q|
      q
    end
  end
  transport :stdio
end
