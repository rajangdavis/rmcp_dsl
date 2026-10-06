# expect: `=~` needs a regex literal
server "refuse", version: "0.1.0" do
  params :P do
    field :s, :string
  end
  tool :t, params: :P, description: "x" do
    body do |s|
      s =~ "x"
    end
  end
  transport :stdio
end
