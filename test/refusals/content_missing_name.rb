# expect: resource_link needs `name:`
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      resource_link("a://b")
    end
  end
  transport :stdio
end
