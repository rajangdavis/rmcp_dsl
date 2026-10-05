# expect: has an invalid prefix
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x", meta: { "1bad.dev/x" => 1 } do
    body do |t|
      t
    end
  end
  transport :stdio
end
