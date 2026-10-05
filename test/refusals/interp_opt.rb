# expect: this value may be nil; use `|| default` or `.to_s` inside the string
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      "first: #{text.split(",").first}"
    end
  end
  transport :stdio
end
