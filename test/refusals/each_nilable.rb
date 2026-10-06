# expect: this value may be nil; use `|| default`, `.nil?` or `.to_s` (not `each`)
server "refuse", version: "0.1.0" do
  params :P do
    field :xs, list(:string), optional: true
  end
  tool :t, params: :P, description: "x" do
    body do |xs|
      xs.each { |x| x }
      "ok"
    end
  end
  transport :stdio
end
