# typed: true
# Tools made from an OpenAPI document: shopkit.openapi.json is read when the server is compiled, and each operation
# becomes a tool that calls the shop's API. The address and the key come from the environment; deleteItem is left out.
server "shopkit", version: "0.1.0", instructions: "Tools for the shop's API" do
  setting :shop_url, env: "SHOPKIT_URL", description: "the shop API's address"
  setting :shop_key, env: "SHOPKIT_KEY", secret: true, description: "the shop API's key"

  openapi "shopkit.openapi.json", base_url: :shop_url, auth_setting: :shop_key, auth_header: "X-Api-Key", exclude: ["deleteItem"]

  transport :stdio
end
