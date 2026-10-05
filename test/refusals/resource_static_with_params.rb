# expect: a resource body takes no parameters
server "refuse", version: "0.1.0" do
  resource :a, uri: "x://notes/all" do
    body do |id|
      id
    end
  end
  transport :stdio
end
