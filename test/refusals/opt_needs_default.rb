# expect: body must return a string, got T.nilable(String); use .to_s
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      text.split(",").first
    end
  end
  transport :stdio
end
