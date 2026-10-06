# expect: settings are read in a tool, prompt or resource body, not in a helper or a binding
server "refuse", version: "0.1.0" do
  setting :v, env: "V"
  helper :h, args: [], returns: :string do
    setting(:v)
  end
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      h
    end
  end
  transport :stdio
end
