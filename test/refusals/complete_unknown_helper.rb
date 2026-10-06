# expect: no helper `nope` declared for `complete:`
server "t", version: "0.1.0" do
  params :P do
    field :topic, :string, complete: :nope
  end

  prompt :p, params: :P, description: "d" do
    body do |topic|
      topic
    end
  end

  transport :stdio
end
