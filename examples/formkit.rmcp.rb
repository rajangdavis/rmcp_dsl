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
    field :ratings, :f64_list, min_items: 1, max_items: 4, optional: true, description: "Optional ratings"
    field :level, :i32, default: 1, min: 1, max: 5, description: "Level, 1 to 5"
    field :quantity, :i32, default: 5, exclusive_min: 0, exclusive_max: 50, multiple_of: 5, description: "How many, in fives"
    field :greeting, :string, default: "hello", description: "Opening word"
    field :address, :Address, description: "Where they live"
    field :billing, :Address, optional: true, description: "Where to bill, if different"
    field :offices, list(:Address), optional: true, min_items: 1, max_items: 3, description: "Branch offices, one to three"
  end

  tool :register, params: :RegisterParams, description: "Describe a registration", read_only: true do
    body do |email, tags, scores, ratings, level, quantity, greeting, address, billing, offices|
      rating_text = (ratings || []).join(",")
      office_text = (offices || []).map { |o| "#{o.city}:#{o.zip}" }.join(",")
      "#{greeting} #{email}: level #{level}, quantity #{quantity}, tags #{tags.join("+")}, total #{scores.sum}, ratings #{rating_text.empty? ? "none" : rating_text}, #{address.city} #{address.zip}, billed #{billing&.zip || "same"}#{office_text.empty? ? "" : ", offices #{office_text}"}"
    end
  end

  params :BranchParams do
    field :offices, list(:Address), description: "Offices to summarise"
  end

  tool :summarize, params: :BranchParams, description: "Summarise a list of offices", read_only: true do
    body do |offices|
      offices.each { |o| o.zip.length }
      lead = offices.first&.city || "none"
      tail = offices.last&.zip || "00000"
      second = offices[1]&.city || "none"
      found = offices.find { |o| o.zip.start_with?("89") }&.city || "none"
      kept = offices.select { |o| o.city.length > 3 }.reverse.map { |o| o.city }.join("|")
      dropped = offices.reject { |o| o.city.length > 3 }.map { |o| o.city }.join("|")
      any = offices.any? { |o| o.zip == "89501" }
      all = offices.all? { |o| o.zip.start_with?("8") }
      counted = offices.count { |o| o.zip.start_with?("8") }
      "#{offices.length}/#{offices.size} empty=#{offices.empty?} first=#{lead} last=#{tail} picked=#{second} found=#{found} any=#{any} all=#{all} count=#{counted} kept=#{kept} dropped=#{dropped}"
    end
  end

  transport :stdio
end
