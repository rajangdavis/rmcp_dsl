# expect: the MIME type is written out, such as "image/png"
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      image("aGk=", t)
    end
  end
  transport :stdio
end
