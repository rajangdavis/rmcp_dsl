# expect: unknown DSL call `tranport` (valid in `server`: 
server "t", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  tool :x, params: :P, description: "d" do
    body do |text|
      text
    end
  end

  tranport :stdio
end
