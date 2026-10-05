# expect: `start_with?` takes a string, not a regex
server "refuse", version: "0.1.0" do
  params :P do
    field :s, :string
  end
  tool :t, params: :P, description: "x" do
    body do |s|
      if s.start_with?(/a/) then "y" else "n" end
    end
  end
  transport :stdio
end
