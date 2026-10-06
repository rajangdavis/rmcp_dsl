# expect: `roots` asks the client for its roots, which only a tool body can do
server "r", version: "0.1.0" do
  feature :roots
  helper :h, args: [], returns: :string do
    roots().length.to_s
  end
  transport :stdio
end
