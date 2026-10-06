# expect: argument `limit` should be i32, got str
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  helper :h, args: [:string], returns: :string, kw: { limit: [:i32, false] } do |text, limit: 0|
    "#{text}#{limit}"
  end

  tool :t, params: :P, description: "x" do
    body do |text|
      h(text, limit: "x")
    end
  end
  transport :stdio
end
