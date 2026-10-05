# expect: `case` used as a value needs an `else` branch
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      case text when "a" then "x" end
    end
  end
  transport :stdio
end
