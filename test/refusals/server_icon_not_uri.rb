# expect: `icon:` must be an http, https or data: URI, got "logo.png"
server "refuse", version: "0.1.0", icon: "logo.png" do
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
