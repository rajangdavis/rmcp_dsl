# expect: duplicate resource uri notes://a
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      text
    end
  end
  resource :one, uri: "notes://a" do
    body do
      "1"
    end
  end
  resource :two, uri: "notes://a" do
    body do
      "2"
    end
  end
  transport :stdio
end
