# expect: `default:` is above `max:`
server "refuse", version: "0.1.0" do
  params :P do
    field :n, :i32, default: 9, max: 5
  end
  tool :t, params: :P, description: "x" do
    body do |n|
      "#{n}"
    end
  end
  transport :stdio
end
