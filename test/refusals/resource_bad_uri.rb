# expect: `uri:` must look like scheme://path
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      text
    end
  end
  resource :r, uri: "readme" do
    body do
      "x"
    end
  end
  transport :stdio
end
