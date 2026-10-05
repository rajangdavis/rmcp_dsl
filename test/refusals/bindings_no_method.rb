# expect: Heck has no method `nope`
server "t", version: "0.1.0" do
  use_bindings :heck

  params :P do
    field :text, :string
  end

  tool :x, params: :P, description: "d" do
    body do |text|
      Heck.nope(text)
    end
  end

  transport :stdio
end
