# expect: `include_tags:` names "nope", which no operation in petstore.json has
server "refuse", version: "0.1.0" do
  setting :url, env: "URL"
  openapi "petstore.json", base_url: :url, include_tags: ["nope"]
  transport :stdio
end
