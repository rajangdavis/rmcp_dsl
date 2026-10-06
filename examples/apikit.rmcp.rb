# typed: true
# Settings, a secret and an HTTP client together: tools that call an API whose address and key come from the
# environment. The key is a secret, so a body can pass it to Http but never print or return it.
server "apikit", version: "0.1.0", instructions: "Tools that call an API" do
  use_bindings :http
  use_bindings :json

  setting :base_url, env: "APIKIT_BASE_URL", default: "http://127.0.0.1:8080", description: "where the API lives"
  setting :token, env: "APIKIT_TOKEN", secret: true, description: "the API's bearer token"

  params :ItemId do
    field :id, :string, description: "An item number", pattern: "^[0-9]+$"
  end

  params :NewItem do
    field :name, :string, description: "The new item's name", min_length: 1
  end

  params :Ping do
    field :verbose, :bool, optional: true, description: "Ignored"
  end

  tool :health, params: :Ping, description: "Ask the API if it is up (no key needed)", read_only: true, open_world: true do
    body do
      Http.get("#{setting(:base_url)}/health") || raise("the API did not answer")
    end
  end

  tool :item, params: :ItemId, description: "Read one item", read_only: true, open_world: true do
    body do |id|
      Http.get_bearer("#{setting(:base_url)}/items/#{id}", setting(:token)) || raise("the API did not answer with success for item #{id}")
    end
  end

  tool :create, params: :NewItem, description: "Create an item; the name is sent as JSON", open_world: true do
    body do |name|
      quoted = Json.to_json(Json.from_text(name))
      Http.post_json_bearer("#{setting(:base_url)}/items", "{\"name\":#{quoted}}", setting(:token)) || raise("the API refused the new item")
    end
  end

  transport :stdio
end
