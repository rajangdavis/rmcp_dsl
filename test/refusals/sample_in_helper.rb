# expect: `sample` asks the client for an LLM completion, which only a tool body can do, not a helper `h` body
server "r", version: "0.1.0" do
  feature :sampling
  helper :h, args: [], returns: :string do
    sample("hi", max_tokens: 4).text || "-"
  end
  params :P do
    field :s, :string
  end
  tool :t, params: :P, description: "d" do
    body do |s|
      h() + s
    end
  end
  transport :stdio
end
