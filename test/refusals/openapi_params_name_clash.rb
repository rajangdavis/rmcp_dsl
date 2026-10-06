# expect: the arguments would be called `ListPetsArgs`, which is already a params or output name
server "refuse", version: "0.1.0" do
  setting :url, env: "URL"
  params :ListPetsArgs do
    field :t, :string
  end
  tool :t, params: :ListPetsArgs, description: "x" do
    body do |t|
      t
    end
  end
  openapi "petstore.json", base_url: :url
  transport :stdio
end
