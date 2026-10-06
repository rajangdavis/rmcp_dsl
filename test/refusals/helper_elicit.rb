# expect: `elicit` is reserved
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end

  helper :elicit, args: [:string], returns: :string do |text|
    text
  end

  tool :t, params: :P, description: "x" do
    body do |t|
      elicit(t)
    end
  end

  transport :stdio
end
