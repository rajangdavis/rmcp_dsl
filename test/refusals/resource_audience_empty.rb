# expect: `audience:` needs at least one
server "refuse", version: "0.1.0" do
  resource :r, uri: "x://y", audience: [] do
    body do
      "text"
    end
  end
  transport :stdio
end
