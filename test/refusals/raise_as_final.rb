# expect: a body cannot end in `raise`
server "refuse", version: "0.1.0" do
  params :P do
    field :s, :string
  end
  tool :t, params: :P, description: "x" do
    body do |s|
      raise "always"
    end
  end
  transport :stdio
end
