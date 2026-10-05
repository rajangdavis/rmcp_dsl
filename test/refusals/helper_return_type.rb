# expect: the helper returns i64 but its body ends in string
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  helper :size, args: [:string], returns: :i64 do |s|
    s.upcase
  end

  tool :t, params: :P, description: "x" do
    body do |text|
      size(text).to_s
    end
  end
  transport :stdio
end
