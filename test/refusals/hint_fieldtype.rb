# expect: did you mean `string`
server "t", version: "0.1.0" do
  params :P do
    field :text, :strng
  end

  tool :x, params: :P, description: "d" do
    body do |text|
      text
    end
  end

  transport :stdio
end
