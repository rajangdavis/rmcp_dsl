# expect: `text` builds a content block, which only a tool body can return
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  prompt :p, params: :P, description: "x" do
    body do |t|
      text(t)
    end
  end
  transport :stdio
end
