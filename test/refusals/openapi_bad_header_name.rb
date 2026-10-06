# expect: is not a valid HTTP header name
server "refuse", version: "0.1.0" do
  setting :url, env: "URL"
  openapi "petstore.json", base_url: :url, auth_setting: :url, auth_header: "X Key"
  transport :stdio
end
