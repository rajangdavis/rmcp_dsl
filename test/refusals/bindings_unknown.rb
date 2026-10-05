# expect: no binding named nonesuch
server "t", version: "0.1.0" do
  use_bindings :nonesuch

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
