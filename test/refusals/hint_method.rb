# expect: unsupported method `upcas` in body (allowed:
server "t", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  tool :x, params: :P, description: "d" do
    body do |text|
      text.upcas
    end
  end

  transport :stdio
end
