# expect: `async: true` is not supported on helper `shout`: async is inferred from the body, so remove `async: true` and call an async rust_fn or binding instead
server "refuse", version: "0.1.0" do
  params :P do
    field :s, :string
  end

  helper :shout, args: [:string], returns: :string, async: true do |s|
    s.upcase
  end

  tool :t, params: :P, description: "x" do
    body do |s|
      shout(s)
    end
  end

  transport :stdio
end
