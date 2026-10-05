# expect: `size: 5` is not the size of the body, which is 2 bytes (UTF-8); use `size: 2`
server "refuse", version: "0.1.0" do
  resource :r, uri: "x://r", size: 5 do
    body do
      "hi"
    end
  end
  transport :stdio
end
