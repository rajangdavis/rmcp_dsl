# expect: a completer takes one :string argument and returns :string_list
server "t", version: "0.1.0" do
  helper :choices, args: [:string], returns: :string do |typed|
    typed
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
