# expect: the tool name `list_pets` is already a tool of this server
server "refuse", version: "0.1.0" do
  setting :url, env: "URL"
  params :P do
    field :t, :string
  end
  tool :list_pets, params: :P, description: "x" do
    body do |t|
      t
    end
  end
  openapi "petstore.json", base_url: :url
  transport :stdio
end
