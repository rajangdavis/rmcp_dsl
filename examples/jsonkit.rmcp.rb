# A server that reads JSON documents without a schema. The DSL never looks inside a document: Json::Value comes from
# bindings/json.rb, which is the only place that knows it is serde_json::Value. A document can arrive as a tool
# field (the client sends any JSON), be parsed from text, and be returned inside a structured result.
server "jsonkit", version: "0.1.0", instructions: "Look inside JSON documents with JSON pointers" do
  use_bindings :json

  params :Text do
    field :text, :string, description: "JSON text"
  end

  params :At do
    field :doc, Json::Value, description: "any JSON document"
    field :path, :string, description: "a JSON pointer such as /a/0/b; empty for the whole document"
  end

  output :Found do
    field :kind, :string, description: "null, boolean, number, string, array or object"
    field :value, Json::Value, description: "the value at the pointer"
  end

  tool :kind_of_text, params: :Text, description: "Parse JSON text and say what kind of value it is" do
    body do |text|
      doc = Json.parse(text) || raise("not valid JSON")
      Json.kind(doc)
    end
  end

  tool :pick, params: :At, description: "The JSON text at a pointer inside a document" do
    body do |doc, path|
      found = Json.pointer(doc, path) || raise("nothing at #{path}")
      Json.to_json(found)
    end
  end

  tool :peek, params: :At, output: :Found, description: "The value at a pointer, with its kind" do
    body do |doc, path|
      found = Json.pointer(doc, path) || raise("nothing at #{path}")
      result(:Found, kind: Json.kind(found), value: found)
    end
  end

  tool :names, params: :At, description: "The member names of the object at a pointer, comma separated" do
    body do |doc, path|
      found = Json.pointer(doc, path) || raise("nothing at #{path}")
      members = Json.keys(found) || raise("#{path} is a #{Json.kind(found)}, not an object")
      members.join(",")
    end
  end

  tool :total, params: :At, description: "The integer at a pointer, plus one" do
    body do |doc, path|
      found = Json.pointer(doc, path) || raise("nothing at #{path}")
      n = Json.integer(found) || raise("#{path} is not an integer")
      (n + 1).to_s
    end
  end

  transport :stdio
end
