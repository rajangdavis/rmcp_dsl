# expect: is not base64 text
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      image("not base64!", "image/png")
    end
  end
  transport :stdio
end
