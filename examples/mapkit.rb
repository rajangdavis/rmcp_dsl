# typed: true
# mapkit: typed maps. A field can be a map from String to one value type (`map(:i64)`, `map(list(:string))`), a body reads
# one with m["key"], fetch, key?, keys, values, size and merge, builds one with a literal or `tally`, and a result can
# carry one. A map is a Rust BTreeMap, as serde_json's own objects are, so its keys come back sorted.
server "mapkit", version: "0.1.0" do
  params :TallyParams do
    field :text, :string, min_length: 1, description: "Comma separated items"
    field :labels, map(:string), optional: true, description: "Extra labels to return"
  end

  output :Tally do
    field :counts, map(:i64), description: "How many times each item appeared"
    field :labels, map(:string), description: "The labels given, plus the source"
    field :first, :string, optional: true, description: "The first item"
  end

  tool :tally, params: :TallyParams, output: :Tally, description: "Count the items", read_only: true do
    body do |text, labels|
      items = text.split(",")
      result(:Tally, counts: items.tally, labels: (labels || {}).merge({ "source" => "tally" }), first: items.first)
    end
  end

  output :Shape do
    field :groups, map(list(:string)), description: "Items by group"
    field :weights, map(:f64), description: "A map of floats"
    field :flags, map(:bool), description: "A map of booleans"
  end

  tool :shape, params: :TallyParams, output: :Shape, description: "Group the items", read_only: true do
    body do |text|
      items = text.split(",")
      result(:Shape, groups: { "all" => items, "sorted" => items.sort }, weights: { "half" => 0.5 },
                     flags: { "empty" => items.empty? })
    end
  end

  params :LookupParams do
    field :scores, map(:i64), description: "Scores by name"
    field :name, :string, description: "Whose score to read"
  end

  tool :lookup, params: :LookupParams, description: "Read one score", read_only: true do
    body do |scores, name|
      "#{name}: #{scores.fetch(name, -1)} of #{scores.size} (#{scores.keys.join("+")}), total #{scores.values.sum}, #{scores.key?(name)}"
    end
  end

  transport :stdio
end
