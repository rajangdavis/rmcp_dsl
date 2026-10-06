# expect: `complete:` and `enum:` cannot be combined
server "t", version: "0.1.0" do
  params :P do
    field :topic, :string, optional: true, enum: ["a", "b"], complete: :choices
  end

  prompt :p, params: :P, description: "d" do
    body do |topic|
      topic
    end
  end

  transport :stdio
end
