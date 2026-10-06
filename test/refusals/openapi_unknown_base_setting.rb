# expect: `base_url:` names setting `nope`, which is not declared
server "refuse", version: "0.1.0" do
  setting :url, env: "URL"
  openapi "petstore.json", base_url: :nope
  transport :stdio
end
