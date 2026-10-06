# expect: `image` builds a content block, which only a tool body or a prompt message can return (a resource body returns a string, text(...) or blob(...))
# This checks a resource body: image(...) is never a resource content, but text(...) and blob(...) are.
# The filename is stale: this refusal is about a resource body, not a prompt.
server "refuse", version: "0.1.0" do
  resource :r, uri: "refuse://r", mime_type: "text/plain" do
    body do
      image("aGk=", "image/png")
    end
  end
  transport :stdio
end
