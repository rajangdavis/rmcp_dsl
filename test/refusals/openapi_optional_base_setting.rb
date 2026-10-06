# expect: `base_url:` needs `url` to always have a value, but it is `optional: true`
server "refuse", version: "0.1.0" do
  setting :url, env: "URL", optional: true
  openapi "petstore.json", base_url: :url
  transport :stdio
end
