# expect: Heck.snake_case: argument `s` should be String, got Integer (i32)
server "t", version: "0.1.0" do
  use_bindings :heck

  params :P do
    field :n, :i32
  end

  tool :x, params: :P, description: "d" do
    body do |n|
      Heck.snake_case(n)
    end
  end

  transport :stdio
end
