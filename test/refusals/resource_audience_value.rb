# expect: `audience:` values are "user" or "assistant", got "bot"
server "refuse", version: "0.1.0" do
  resource :r, uri: "x://y", audience: ["bot"] do
    body do
      "text"
    end
  end
  transport :stdio
end
