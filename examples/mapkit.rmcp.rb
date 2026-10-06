# typed: true
# mapkit: typed maps. A field can be a map from String to one value type (`map(:i64)`, `map(list(:string))`), a body reads
# one with m["key"], fetch, key?, keys, values, size and merge, builds one with a literal or `tally`, and a result can
# carry one. A map is a Rust BTreeMap, as serde_json's own objects are, so its keys come back sorted.
server "mapkit", version: "0.1.0" do
  params :TallyParams do
    field :text, :string, min_length: 1, description: "Comma separated items"
    field :labels, map(:string), optional: true, min_items: 1, description: "Extra labels to return"
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

  params :PickParams do
    field :text, :string, description: "A line to search for the first digit"
    field :scores, map(:i64), description: "Scores by name"
    field :threshold, :i64, description: "Keep scores above this"
  end

  output :Picked do
    field :index, :i64, description: "Character index of the first digit, or -1"
    field :kept, map(:i64), description: "Scores above the threshold"
    field :dropped, map(:i64), description: "The scores the filter dropped"
    field :names, list(:string), description: "The kept names and scores, sorted"
  end

  tool :pick, params: :PickParams, output: :Picked, description: "Find a digit and filter scores", read_only: true do
    body do |text, scores, threshold|
      kept = scores.select { |k, v| !k.empty? && v > threshold }
      result(:Picked,
             index: (text =~ /\d/) || -1,
             kept: kept,
             dropped: scores.reject { |k, v| !k.empty? && v > threshold },
             names: kept.map { |k, v| k + "=" + v.to_s })
    end
  end

  # `each` on a map runs the block for its effects; the block takes exactly |k, v|. A negative score
  # raises, which ends the tool call with an error result.
  tool :check_scores, params: :LookupParams, description: "Refuse a map with a negative score" do
    body do |scores, name|
      scores.each { |k, v| raise("negative score for #{k}") if v < 0 }
      "#{name}: #{scores.size} scores"
    end
  end

  # A map of objects and a map of maps. `map(:Member)` is a BTreeMap<String, Member>; `map(map(:i64))` is a
  # BTreeMap<String, BTreeMap<String, i64>>. The body indexes them, iterates, selects and merges them.
  params :Member do
    field :name, :string, description: "Display name"
    field :level, :i64, min: 0, description: "Level, zero or more"
  end

  params :OrgParams do
    field :roster, map(:Member), description: "Members by handle"
    field :extra, map(:Member), optional: true, description: "More members, merged over the roster"
    field :grid, map(map(:i64)), description: "Counts by row and column"
  end

  output :Org do
    field :matrix, map(map(:i64)), description: "Counts by row and column"
    field :lines, list(:string), description: "One line per member"
    field :total, :i64, description: "The sum of every grid cell"
    field :summary, :string, description: "The first member, one grid cell and the kept count"
  end

  tool :org, params: :OrgParams, output: :Org, description: "Summarise members and a grid", read_only: true do
    body do |roster, extra, grid|
      first = roster["ann"]&.name || "none"
      roster.each { |handle, member| raise("bad handle #{handle}") if handle.empty? || member.level < 0 }
      kept = roster.select { |handle, member| !handle.empty? && member.level >= 2 }
      all = (extra || {}).merge(roster)
      lines = all.values.map { |member| "#{member.name}=#{member.level}" }
      cell = grid["a"]["b"] || -1
      total = grid.values.map { |row| row.values.sum }.sum
      result(:Org, matrix: grid, lines: lines, total: total, summary: "#{first} #{cell} kept=#{kept.size}")
    end
  end

  transport :stdio
end
