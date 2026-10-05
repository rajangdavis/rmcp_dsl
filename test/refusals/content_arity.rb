# expect: image takes 2 positional argument(s) (data, mime), got 1
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      image("aGk=")
    end
  end
  transport :stdio
end
