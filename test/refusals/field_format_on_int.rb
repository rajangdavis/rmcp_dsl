# expect: `format:` applies to :string fields, not :i32
server "refuse", version: "0.1.0" do
  params :P do
    field :n, :i32, format: :email
  end
  tool :t, params: :P, description: "x" do
    body do |n|
      "#{n}"
    end
  end
  transport :stdio
end
