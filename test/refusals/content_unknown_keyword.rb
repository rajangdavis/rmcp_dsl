# expect: image has no keyword `alt:` (it has: audience:, priority:)
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      image("aGk=", "image/png", alt: t)
    end
  end
  transport :stdio
end
