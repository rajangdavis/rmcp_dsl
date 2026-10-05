# expect: a resource body takes no parameters
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      text
    end
  end
  resource :r, uri: "notes://a" do
    body do |x|
      "x"
    end
  end
  transport :stdio
end
