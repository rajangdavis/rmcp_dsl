# expect: says `resource_list_changed: true`, but the server declares no resources
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x", resource_list_changed: true do
    body do |t|
      t
    end
  end
  transport :stdio
end
