# expect: the `gsub` block must return a string, got i64
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      text.gsub(/a/) { |m| m.length }.to_s
    end
  end
  transport :stdio
end
