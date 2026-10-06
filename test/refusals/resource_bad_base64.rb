# expect: is not base64 text
server "refuse", version: "0.1.0" do
  resource :r, uri: "refuse://r" do
    body do
      blob("not base64!")
    end
  end
  transport :stdio
end
