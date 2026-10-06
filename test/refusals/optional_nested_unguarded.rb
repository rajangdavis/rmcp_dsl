# expect: this value may be nil; use `|| default`, `.nil?` or `.to_s` (not `upcase`)
server "refuse", version: "0.1.0" do
  params :Address do
    field :city, :string
  end
  params :P do
    field :a, :Address, optional: true
  end
  tool :t, params: :P, description: "x" do
    body do |a|
      a&.city.upcase
    end
  end
  transport :stdio
end