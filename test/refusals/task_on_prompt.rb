# expect: unknown keyword `task:` for `prompt`
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  prompt :p, params: :P, description: "x", task: true do
    body do |t|
      t
    end
  end
  transport :stdio
end
