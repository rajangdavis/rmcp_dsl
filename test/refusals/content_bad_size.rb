# expect: the size is a number of bytes written out, zero or more
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      resource_link("a://b", name: t, size: -1)
    end
  end
  transport :stdio
end
