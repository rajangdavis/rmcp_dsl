# expect: needs `"properties"`
server "refuse", version: "0.1.0" do
  params :P do
    field :q, :string
    field :n, :i64, optional: true
  end
  tool :t, params: :P, description: "x", input_schema: { "type" => "object" } do
    body do |q|
      q
    end
  end
  transport :stdio
end
