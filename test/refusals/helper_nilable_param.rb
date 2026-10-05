# expect: a helper parameter cannot be nil-able yet (:string?)
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  helper :f, args: [:string?], returns: :string do |s|
    s.to_s
  end

  tool :t, params: :P, description: "x" do
    body do |text|
      f(text)
    end
  end
  transport :stdio
end
