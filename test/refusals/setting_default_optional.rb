# expect: a setting with a `default:` is never missing
server "refuse", version: "0.1.0" do
  setting :v, env: "V", default: "x", optional: true
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
