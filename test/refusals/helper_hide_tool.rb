# expect: `hide_tool` is reserved; pick another helper name
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end

  helper :hide_tool, args: [:string], returns: :string do |text|
    text
  end

  tool :t, params: :P, description: "x" do
    body do |t|
      t
    end
  end

  transport :stdio
end
