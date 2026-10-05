# expect: unknown keyword `descripton:` for `tool` (allowed: params, description, title, read_only, destructive, idempotent, open_world, output, icon, meta, task, task_ttl_ms, task_poll_ms, updates, resource_list_changed); did you mean `description`
server "t", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  tool :x, params: :P, description: "d", descripton: "x" do
    body do |text|
      text
    end
  end

  transport :stdio
end
