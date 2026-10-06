# expect: that `kw:` does not declare
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  helper :h, args: [:string], returns: :string do |text, x: 1|
    "#{text}#{x}"
  end

  tool :t, params: :P, description: "x" do
    body do |text|
      h(text)
    end
  end
  transport :stdio
end
