# expect: `unless` used as a value needs an `else` branch
server "refuse", version: "0.1.0" do
  params :P do
    field :s, :string
  end
  tool :t, params: :P, description: "x" do
    body do |s|
      unless s == "a"
        "y"
      end
    end
  end
  transport :stdio
end
