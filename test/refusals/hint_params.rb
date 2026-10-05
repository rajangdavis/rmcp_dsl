# expect: refers to undeclared params `Q` (declared above: P); did you mean `P`
server "t", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  tool :x, params: :Q, description: "d" do
    body do |text|
      text
    end
  end

  transport :stdio
end
