# expect: a completer takes one :string argument and returns :string_list
server "t", version: "0.1.0" do
  helper :choices, args: [:string, :string], returns: :string_list do |a, b|
    ["x"].select { |v| v.start_with?(a) && v.start_with?(b) }
  end

  params :P do
    field :topic, :string, complete: :choices
  end

  prompt :p, params: :P, description: "d" do
    body do |topic|
      topic
    end
  end

  transport :stdio
end
