# expect: sample needs `max_tokens:`
server "r", version: "0.1.0" do
  feature :sampling
  params :P do
    field :s, :string
  end
  tool :t, params: :P, description: "d" do
    body do |s|
      sample(s).text || "-"
    end
  end
  transport :stdio
end
