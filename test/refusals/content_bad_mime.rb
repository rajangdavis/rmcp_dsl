# expect: is not a MIME type (type/subtype, such as image/png)
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      image("aGk=", "png")
    end
  end
  transport :stdio
end
