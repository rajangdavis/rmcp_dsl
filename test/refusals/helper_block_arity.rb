# expect: helper `f` declares 2 argument type(s) but its block takes 1
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  helper :f, args: [:string, :i64], returns: :string do |s|
    s
  end

  tool :t, params: :P, description: "x" do
    body do |text|
      f(text, 1)
    end
  end
  transport :stdio
end
