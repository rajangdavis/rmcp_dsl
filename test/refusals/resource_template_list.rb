# expect: placeholder `{b}` has no field in params `P`
server "refuse", version: "0.1.0" do
  params :P do
    field :id, :string
  end
  resource :r, uri: "x://a/{id,b}", params: :P do
    body do |id|
      "text#{id}"
    end
  end
  transport :stdio
end
