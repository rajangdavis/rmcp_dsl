# expect: this value may be nil; use `|| default`, `.nil?` or `.to_s` (not `upcase`)
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      text.split(",").first.upcase
    end
  end
  transport :stdio
end
