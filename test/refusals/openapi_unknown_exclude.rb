# expect: `exclude:` names "nope", which is not an operation of petstore.json
server "refuse", version: "0.1.0" do
  setting :url, env: "URL"
  openapi "petstore.json", base_url: :url, exclude: ["nope"]
  transport :stdio
end
