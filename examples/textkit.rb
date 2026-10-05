# typed: true
server "textkit", version: "0.1.0" do
  params :TextParams do
    field :text, :string
  end

  tool :slug, params: :TextParams, description: "Lowercase text with each run of non-alphanumerics turned into one hyphen" do
    body do |text|
      text.strip.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
    end
  end

  tool :word_count, params: :TextParams, description: "Count the whitespace-separated words" do
    body do |text|
      text.split.length.to_s
    end
  end

  tool :redact_digits, params: :TextParams, description: "Replace every ASCII digit with #" do
    body do |text|
      text.gsub(/\d/, "#")
    end
  end

  tool :title_case, params: :TextParams, description: "Capitalize each whitespace-separated word and join with single spaces" do
    body do |text|
      text.split.map { |w| w.capitalize }.join(" ")
    end
  end

  transport :stdio
end
