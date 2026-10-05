# expect: `task_ttl_ms:` must be at least 1 millisecond
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x", task: true, task_ttl_ms: 0 do
    body do |t|
      t
    end
  end
  transport :stdio
end
