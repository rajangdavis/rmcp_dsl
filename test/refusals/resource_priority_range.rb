# expect: `priority:` is between 0 and 1
server "refuse", version: "0.1.0" do
  resource :r, uri: "x://y", priority: 2 do
    body do
      "text"
    end
  end
  transport :stdio
end
