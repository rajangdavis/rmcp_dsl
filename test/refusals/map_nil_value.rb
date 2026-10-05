# expect: a map value cannot be nil
server "refuse", version: "0.1.0" do
  params :P do
    field :m, map(:i64)
    field :s, :string, optional: true
  end
  tool :t, params: :P, description: "x" do
    body do |m, s|
      { "a" => s }.size.to_s
    end
  end
  transport :stdio
end
