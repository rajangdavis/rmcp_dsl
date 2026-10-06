# expect: openapi file not found: nope.json
server "refuse", version: "0.1.0" do
  setting :url, env: "URL"
  openapi "nope.json", base_url: :url
  transport :stdio
end
