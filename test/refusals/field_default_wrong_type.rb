# expect: `default:` must be an integer for the :i32 field
server "refuse", version: "0.1.0" do
  params :P do
    field :n, :i32, default: "x"
  end
  tool :t, params: :P, description: "x" do
    body do |n|
      "#{n}"
    end
  end
  transport :stdio
end
