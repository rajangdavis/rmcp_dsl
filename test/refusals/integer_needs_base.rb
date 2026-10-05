# expect: Integer needs the base written out
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      Integer(text).to_s
    end
  end
  transport :stdio
end
