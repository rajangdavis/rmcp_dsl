# expect: duplicate key "a"
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x", meta: { "a" => 1, "a" => 2 } do
    body do |t|
      t
    end
  end
  transport :stdio
end
