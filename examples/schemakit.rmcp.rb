# typed: true
# A hand-written input schema: `input_schema:` replaces the schema made from the fields, for a schema that says more
# than fields can (examples, vendor keywords, descriptions of the whole object) or that comes from somewhere else. The
# compiler still checks it against the fields, so it cannot promise an argument shape the server does not accept.
server "schemakit", version: "0.1.0", instructions: "search takes the schema written out in the file" do
  params :Search do
    field :query, :string
    field :limit, :i64, optional: true
  end

  tool :search, params: :Search, description: "Pretend to search",
                input_schema: {
                  "$schema" => "https://json-schema.org/draft/2020-12/schema",
                  "title" => "Search arguments",
                  "type" => "object",
                  "properties" => {
                    "query" => { "type" => "string", "description" => "What to look for", "examples" => ["cats", "dogs"] },
                    "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 100, "description" => "How many answers" }
                  },
                  "required" => ["query"],
                  "additionalProperties" => false
                } do
    body do |query, limit|
      "#{query}|#{limit || 10}"
    end
  end

  transport :stdio
end
