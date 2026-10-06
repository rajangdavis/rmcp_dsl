# expect: `auth_scheme:` is one word such as Bearer or Basic
server "refuse", version: "0.1.0" do
  setting :url, env: "URL"
  openapi "petstore.json", base_url: :url, auth_setting: :url, auth_scheme: "two words"
  transport :stdio
end
