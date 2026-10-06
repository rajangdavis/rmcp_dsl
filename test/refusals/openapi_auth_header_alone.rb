# expect: `auth_header:` and `auth_scheme:` need `auth_setting:`
server "refuse", version: "0.1.0" do
  setting :url, env: "URL"
  openapi "petstore.json", base_url: :url, auth_header: "X-Key"
  transport :stdio
end
