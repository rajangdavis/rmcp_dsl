# expect: `main` is reserved; pick another helper name
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  helper :main, args: [:string], returns: :string do |s|
    s
  end

  tool :t, params: :P, description: "x" do
    body do |text|
      main(text)
    end
  end
  transport :stdio
end
