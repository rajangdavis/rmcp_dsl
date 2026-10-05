# expect: does not fit JSON number range
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x", meta: { "a" => 99999999999999999999999 } do
    body do |t|
      t
    end
  end
  transport :stdio
end
