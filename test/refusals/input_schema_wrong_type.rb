# expect: says property `n` is string, but the field is :i64 (integer)
server "refuse", version: "0.1.0" do
  params :P do
    field :q, :string
    field :n, :i64, optional: true
  end
  tool :t, params: :P, description: "x", input_schema: { "type" => "object", "properties" => { "q" => { "type" => "string" }, "n" => { "type" => "string" } }, "required" => ["q"] } do
    body do |q|
      q
    end
  end
  transport :stdio
end
