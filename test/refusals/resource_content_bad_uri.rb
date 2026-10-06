# expect: is not a URI
server "refuse", version: "0.1.0" do
  resource :r, uri: "refuse://r" do
    body do
      text("hi", uri: "not a uri")
    end
  end
  transport :stdio
end
