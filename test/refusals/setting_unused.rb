# expect: setting `v` is declared but no body reads it
server "refuse", version: "0.1.0" do
  setting :v, env: "V"
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      t
    end
  end
  transport :stdio
end
