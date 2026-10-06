# expect: declare `feature :roots` to use `roots`
server "r", version: "0.1.0" do
  params :P do
    field :s, :string
  end
  tool :t, params: :P, description: "d" do
    body do |s|
      roots().length.to_s
    end
  end
  transport :stdio
end
