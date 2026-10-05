# expect: unknown constant `Heck`; bindings are loaded with use_bindings :name
server "t", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  tool :x, params: :P, description: "d" do
    body do |text|
      Heck.snake_case(text)
    end
  end

  transport :stdio
end
