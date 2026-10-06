# expect: the document gives no address to send requests to
server "refuse", version: "0.1.0" do
  setting :url, env: "URL"
  openapi "shop31.yaml"
  transport :stdio
end
