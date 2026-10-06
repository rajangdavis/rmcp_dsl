# expect: `default:` and `optional:` cannot be combined
server "refuse", version: "0.1.0" do
  params :Address do
    field :city, :string
  end
  params :P do
    field :a, :Address, optional: true, default: "x"
  end
  tool :t, params: :P, description: "x" do
    body do |a|
      a&.city || "none"
    end
  end
  transport :stdio
end