# expect: a helper can only be called after it is declared
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  helper :first, args: [:string], returns: :string do |s|
    second(s)
  end

  helper :second, args: [:string], returns: :string do |s|
    s.upcase
  end

  tool :t, params: :P, description: "x" do
    body do |text|
      first(text) + second(text)
    end
  end
  transport :stdio
end
