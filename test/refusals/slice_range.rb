# expect: string ranges are not supported; use s[start, length]
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      text[0..2] || ""
    end
  end
  transport :stdio
end
