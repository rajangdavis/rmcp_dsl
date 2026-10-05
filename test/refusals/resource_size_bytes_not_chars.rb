# expect: `size: 2` is not the size of the body, which is 3 bytes (UTF-8); use `size: 3`
server "refuse", version: "0.1.0" do
  resource :r, uri: "x://r", size: 2 do
    body do
      "é!"
    end
  end
  transport :stdio
end
