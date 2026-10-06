# expect: only a resource body can return
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do
      blob("aGk=")
    end
  end
  transport :stdio
end
