# expect: `audience:` values must be distinct
server "refuse", version: "0.1.0" do
  resource :r, uri: "x://y", audience: ["user", "user"] do
    body do
      "text"
    end
  end
  transport :stdio
end
