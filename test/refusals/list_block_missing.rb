# expect: `find` needs a literal { |x| ... } block
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      text.split.find || "x"
    end
  end
  transport :stdio
end
