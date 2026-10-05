# expect: only a guard clause is allowed as a statement
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      if text.empty?
        return "a"
      else
        return "b"
      end
      text
    end
  end
  transport :stdio
end
