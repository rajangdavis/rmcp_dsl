# expect: `task_ttl_ms:` only applies with `task: true`
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x", task_ttl_ms: 1000 do
    body do |t|
      t
    end
  end
  transport :stdio
end
