# expect: helper `shout`: argument `s` should be string, got int
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  helper :shout, args: [:string], returns: :string do |s|
    s.upcase
  end

  tool :t, params: :P, description: "x" do
    body do |text|
      shout(5) + text
    end
  end
  transport :stdio
end
