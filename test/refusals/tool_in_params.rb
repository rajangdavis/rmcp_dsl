# expect: `tool` is not allowed in `params`
server "t", version: "0.1.0" do
  params :P do
    field :text, :string
    tool :x, params: :P, description: "d" do
      body do |text|
        text
      end
    end
  end

  transport :stdio
end
