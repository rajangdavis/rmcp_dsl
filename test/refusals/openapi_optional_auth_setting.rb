# expect: `auth_setting:` needs `key` to always have a value, but it is `optional: true`
server "refuse", version: "0.1.0" do
  setting :url, env: "URL"
  setting :key, env: "KEY", optional: true
  openapi "petstore.json", base_url: :url, auth_setting: :key
  transport :stdio
end
