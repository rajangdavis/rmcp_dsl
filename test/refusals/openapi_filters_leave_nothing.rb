# expect: the filters leave no operation of petstore.json
server "refuse", version: "0.1.0" do
  setting :url, env: "URL"
  openapi "petstore.json", base_url: :url, include_tags: ["admin"], exclude: ["deletePet"]
  transport :stdio
end
