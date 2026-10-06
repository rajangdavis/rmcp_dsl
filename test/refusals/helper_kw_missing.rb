# expect: is missing required keyword `limit:`
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  helper :h, args: [:string], returns: :string, kw: { limit: [:i32, true] } do |text, limit:|
    "#{text}#{limit}"
  end

  tool :t, params: :P, description: "x" do
    body do |text|
      h(text)
    end
  end
  transport :stdio
end
