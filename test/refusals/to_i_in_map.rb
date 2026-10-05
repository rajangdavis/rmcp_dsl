# expect: integer arithmetic, `to_i`, `raise` or `return` inside a gsub block is not supported yet
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      text.gsub(/\d+/) { |m| m.to_i.to_s }
    end
  end
  transport :stdio
end
