# expect: is a top-level declaration, and the enclosing tool
server "t", version: "0.1.0" do
  params :P do
    field :a, :string
  end

  tool :x, params: :P, description: "d" do
    body do |a|
      params :Q do
        field :b, :string
      end
      a
    end
  end

  transport :stdio
end
