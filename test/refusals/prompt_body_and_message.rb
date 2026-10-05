# expect: use either one `body` or one or more `message` blocks in a prompt, not both
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  prompt :p, params: :P, description: "x" do
    body do |t|
      t
    end
    message :assistant do
      "hello"
    end
  end
  transport :stdio
end
