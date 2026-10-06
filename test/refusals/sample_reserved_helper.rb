# expect: `sample` is reserved; pick another helper name
server "r", version: "0.1.0" do
  helper :sample, args: [], returns: :string do
    "x"
  end
  params :P do
    field :s, :string
  end
  tool :t, params: :P, description: "d" do
    body do |s|
      s
    end
  end
  transport :stdio
end
