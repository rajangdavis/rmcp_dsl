# expect: helper `shout` takes 1 argument(s), got 2
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  helper :shout, args: [:string], returns: :string do |s|
    s.upcase
  end

  tool :t, params: :P, description: "x" do
    body do |text|
      shout(text, text)
    end
  end
  transport :stdio
end
