# expect: did you mean `uniq`
server "t", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  tool :x, params: :P, description: "d" do
    body do |text|
      text.split(",").uniqq.join("+")
    end
  end

  transport :stdio
end
