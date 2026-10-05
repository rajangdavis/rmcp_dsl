# expect: a list of :user and/or :assistant, such as [:user]
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      text(t, audience: [:robot])
    end
  end
  transport :stdio
end
