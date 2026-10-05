# expect: the `select` block must return true or false, got i64
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      text.split.select { |w| w.length }.join(",")
    end
  end
  transport :stdio
end
