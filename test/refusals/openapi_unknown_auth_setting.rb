# expect: `auth_setting:` names setting `nope`, which is not declared
server "refuse", version: "0.1.0" do
  setting :url, env: "URL"
  openapi "petstore.json", base_url: :url, auth_setting: :nope
  transport :stdio
end
