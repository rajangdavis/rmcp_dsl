# expect: use_bindings :heck is declared but no body calls Heck.<method>
server "t", version: "0.1.0" do
  use_bindings :heck

  params :P do
    field :text, :string
  end

  tool :x, params: :P, description: "d" do
    body do |text|
      text
    end
  end

  transport :stdio
end
