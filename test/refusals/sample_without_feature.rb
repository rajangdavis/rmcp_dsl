# expect: declare `feature :sampling` to use `sample`
server "r", version: "0.1.0" do
  params :P do
    field :s, :string
  end
  tool :t, params: :P, description: "d" do
    body do |s|
      sample(s, max_tokens: 8).text || "-"
    end
  end
  transport :stdio
end
