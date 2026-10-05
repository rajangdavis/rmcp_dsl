# expect: local `leftover` is never read
server "t", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  tool :x, params: :P, description: "d" do
    body do |text|
      leftover = text.upcase
      text
    end
  end

  transport :stdio
end
