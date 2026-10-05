# expect: `unused` is declared but never called
server "t", version: "0.1.0" do
  cmd_fn :unused, program: "tr", args: [:string], returns: :string

  params :P do
    field :text, :string
  end

  tool :x, params: :P, description: "d" do
    body do |text|
      text
    end
  end

  transport :stdio
end
