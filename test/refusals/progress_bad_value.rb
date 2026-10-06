# expect: progress value must be a number, got String
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      progress("nope")
      t
    end
  end
  transport :stdio
end
