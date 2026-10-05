# expect: `default:` and `optional:` cannot be combined
server "refuse", version: "0.1.0" do
  params :P do
    field :n, :i32, default: 1, optional: true
  end
  tool :t, params: :P, description: "x" do
    body do |n|
      "#{n}"
    end
  end
  transport :stdio
end
