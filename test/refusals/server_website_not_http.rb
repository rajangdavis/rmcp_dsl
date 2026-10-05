# expect: `website_url:` must be an http or https address, got "data:text/plain,hi"
server "refuse", version: "0.1.0", website_url: "data:text/plain,hi" do
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
