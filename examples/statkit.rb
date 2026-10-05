# typed: true
# statkit: structured output. A tool declares an `output` and returns typed JSON; clients read it by
# field name, and the tool list publishes the shape as an output schema. `result(:Name, ...)` builds one.
server "statkit", version: "0.1.0" do
  params :TextParams do
    field :text, :string, min_length: 1, description: "Comma separated items"
  end

  output :Counts do
    field :items, :i64, description: "How many items"
    field :unique, :i64, description: "How many different items"
  end

  output :Stats do
    field :text, :string, description: "The text that was measured"
    field :counts, :Counts, description: "How big it is"
    field :items, :string_list, description: "The items, upper-cased"
    field :first, :string, optional: true, description: "The first item"
    field :shout, :bool, description: "Whether the text is already upper case"
  end

  tool :stats, params: :TextParams, output: :Stats, description: "Measure a comma separated text", read_only: true do
    body do |text|
      items = text.split(",")
      raise "no items" if items.empty?
      result(:Stats, text: text, counts: result(:Counts, items: items.length, unique: items.uniq.length),
                     items: items.map { |i| i.upcase }, first: items.first, shout: text == text.upcase)
    end
  end

  transport :stdio
end
