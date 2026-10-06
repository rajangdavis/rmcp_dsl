# expect: `roots` is reserved; pick another helper name
server "r", version: "0.1.0" do
  helper :roots, args: [], returns: :string do
    "x"
  end
  transport :stdio
end
