# expect: parameter `other` is never read
server "t", version: "0.1.0" do
  params :P do
    field :text, :string
    field :other, :string
  end

  tool :x, params: :P, description: "d" do
    body do |text, other|
      text
    end
  end

  transport :stdio
end
