# expect: Heck.snake_case takes 1 argument(s), got 2
server "t", version: "0.1.0" do
  use_bindings :heck

  params :P do
    field :text, :string
  end

  tool :x, params: :P, description: "d" do
    body do |text|
      Heck.snake_case(text, text)
    end
  end

  transport :stdio
end
