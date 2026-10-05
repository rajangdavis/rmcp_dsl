# expect: `min:` is above `max:`
server "refuse", version: "0.1.0" do
  params :P do
    field :n, :i32, min: 5, max: 1
  end
  tool :t, params: :P, description: "x" do
    body do |n|
      n.to_s
    end
  end
  transport :stdio
end
