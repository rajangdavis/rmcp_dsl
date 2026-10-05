# expect: a helper can only be called after it is declared
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  helper :again, args: [:string], returns: :string do |s|
    again(s)
  end

  tool :t, params: :P, description: "x" do
    body do |text|
      again(text)
    end
  end
  transport :stdio
end
