# expect: only a tool body or a prompt message can return
server "refuse", version: "0.1.0" do
  resource :r, uri: "refuse://r" do
    body do
      resource_link("refuse://other", name: "other")
    end
  end
  transport :stdio
end
