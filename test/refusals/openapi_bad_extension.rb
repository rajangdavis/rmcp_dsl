# expect: must be relative, inside the DSL file's folder, without .., and end in .json, .yaml or .yml
server "refuse", version: "0.1.0" do
  setting :url, env: "URL"
  openapi "spec.txt", base_url: :url
  transport :stdio
end
