# expect: `client_name` is reserved; pick another helper name
server "refuse", version: "0.1.0" do
  helper :client_name, args: [], returns: :string do
    "x"
  end
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
