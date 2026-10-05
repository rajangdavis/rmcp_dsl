# expect: `task: false` is the default; leave `task:` out
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x", task: false do
    body do |t|
      t
    end
  end
  transport :stdio
end
