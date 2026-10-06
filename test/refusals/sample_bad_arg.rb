# expect: sample's max_tokens: must be an integer, got String
server "r", version: "0.1.0" do
  feature :sampling
  params :P do
    field :s, :string
  end
  tool :t, params: :P, description: "d" do
    body do |s|
      sample(s, max_tokens: s).text || "-"
    end
  end
  transport :stdio
end
