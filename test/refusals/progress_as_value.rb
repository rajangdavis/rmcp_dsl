# expect: `progress` is a statement, not a value; write it on its own line
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      p = progress(1)
      t
    end
  end
  transport :stdio
end
