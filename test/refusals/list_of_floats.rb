# expect: a list of floats only supports
server "refuse", version: "0.1.0" do
  params :P do
    field :m, list(:f64)
  end
  tool :t, params: :P, description: "x" do
    body do |m|
      m.tally.size.to_s
    end
  end
  transport :stdio
end
