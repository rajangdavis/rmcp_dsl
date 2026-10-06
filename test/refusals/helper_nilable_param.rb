# expect: this value may be nil; use `|| default`, `.nil?` or `.to_s` (not `upcase`)
# A nil-able helper parameter now compiles (Wave B-b), so this same shape is refused for a different
# reason: the body must consume the nil-able parameter with `||`, `.nil?` or `.to_s`.
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  helper :f, args: [:string?], returns: :string do |s|
    s.upcase
  end

  tool :t, params: :P, description: "x" do
    body do |text|
      f(text)
    end
  end
  transport :stdio
end
