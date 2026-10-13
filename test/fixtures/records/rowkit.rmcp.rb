# A server whose binding returns records (docs/specs/typed_record.md): test/test_records.rb builds it, reads the
# rows' fields in bodies, returns them as an output, and checks the record against its Rust struct.
server "rowkit", version: "0.1.0" do
  use_bindings :rows
  rust_file "rust/rows.rs", as: :rows

  params :P do
    field :count, :i64, default: 3
  end

  output :Places do
    field :places, list(Rows::Row)
  end

  tool :places, params: :P, output: :Places, description: "The rows, as structured output" do
    body do |count|
      result(:Places, places: Rows.make(count))
    end
  end

  tool :summary, params: :P, description: "How many rows, the first one's link, and their texts" do
    body do |count|
      rows = Rows.make(count)
      link = rows.first&.href || "none"
      texts = rows.map { |r| r.text }
      "#{rows.length} #{link} #{texts.join(",")}"
    end
  end

  transport :stdio
end
