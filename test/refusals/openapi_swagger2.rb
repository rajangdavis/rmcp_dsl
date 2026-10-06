# expect: is a Swagger 2.0 document; only OpenAPI 3.0 and 3.1
server "refuse", version: "0.1.0" do
  setting :url, env: "URL"
  openapi "swagger2.json", base_url: :url
  transport :stdio
end
