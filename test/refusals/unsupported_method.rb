# expect: unsupported method `center` in body
server "t", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  tool :x, params: :P, description: "d" do
    body do |text|
      text.center(20)
    end
  end

  transport :stdio
end
