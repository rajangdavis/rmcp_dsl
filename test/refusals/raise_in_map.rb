# expect: the `map` block must return a string or an integer, got never
server "refuse", version: "0.1.0" do
  params :P do
    field :s, :string
  end
  tool :t, params: :P, description: "x" do
    body do |s|
      s.split.map { |w| raise("no") }.join(" ")
    end
  end
  transport :stdio
end
