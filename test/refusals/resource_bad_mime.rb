# expect: is not a MIME type
server "refuse", version: "0.1.0" do
  resource :r, uri: "refuse://r" do
    body do
      blob("aGk=", mime_type: "png")
    end
  end
  transport :stdio
end
