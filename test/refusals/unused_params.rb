# expect: params `Extra` is declared but no tool uses it
server "t", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  params :Extra do
    field :n, :i32
  end

  tool :x, params: :P, description: "d" do
    body do |text|
      text
    end
  end

  transport :stdio
end
