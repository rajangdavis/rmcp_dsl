# expect: must be relative, inside the DSL file's folder
server "refuse", version: "0.1.0" do
  setting :url, env: "URL"
  openapi "../petstore.json", base_url: :url
  transport :stdio
end
