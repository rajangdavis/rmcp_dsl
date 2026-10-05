# expect: this `case` compares strings, but `when` has an integer
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      case text when 1 then "a" else "b" end
    end
  end
  transport :stdio
end
