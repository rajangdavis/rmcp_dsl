# expect: should be i64, got oi64
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  helper :plain, args: [:i64], returns: :string do |n|
    n.to_s
  end

  tool :t, params: :P, description: "x" do
    body do |text|
      plain(text.index("/"))
    end
  end
  transport :stdio
end
