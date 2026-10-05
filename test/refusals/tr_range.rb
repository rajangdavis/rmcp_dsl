# expect: with ranges (a-z), `^` or backslashes is not supported
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      text.tr("a-c", "xyz")
    end
  end
  transport :stdio
end
