# typed: true
# formkit: richer tool inputs. List fields with size limits, a nested object, defaults, and a format.
server "formkit", version: "0.1.0" do
  params :Address do
    field :city, :string, description: "City name"
    field :zip, :string, pattern: "^[0-9]{5}$", description: "Five digit postal code"
  end

  params :RegisterParams do
    field :email, :string, format: :email, description: "Contact address"
    field :tags, :string_list, min_items: 1, max_items: 3, description: "One to three tags"
    field :scores, :i64_list, description: "Scores to add up"
    field :level, :i32, default: 1, min: 1, max: 5, description: "Level, 1 to 5"
    field :greeting, :string, default: "hello", description: "Opening word"
    field :address, :Address, description: "Where they live"
  end

  tool :register, params: :RegisterParams, description: "Describe a registration", read_only: true do
    body do |email, tags, scores, level, greeting, address|
      "#{greeting} #{email}: level #{level}, tags #{tags.join("+")}, total #{scores.sum}, #{address.city} #{address.zip}"
    end
  end

  transport :stdio
end
