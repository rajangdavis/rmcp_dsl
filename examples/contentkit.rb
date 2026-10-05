# typed: true
# Tool results that are not one string: images, audio, links to resources and embedded resources, alone or several in
# one result. The body ends in one content block or an array of them. Literal base64, MIME types and URIs are checked
# when the server is compiled.
server "contentkit", version: "0.1.0", instructions: "Tools that answer with images, audio and resources" do
  params :Label do
    field :label, :string, description: "What to put in the answer"
  end

  tool :logo, params: :Label, description: "A text block and an image (a 1x1 PNG)" do
    body do |label|
      raise("label is empty") if label.empty?
      [
        text("Logo for #{label}"),
        image("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==", "image/png",
              audience: [:user], priority: 0.5)
      ]
    end
  end

  tool :beep, params: :Label, description: "One audio block (an empty WAV)" do
    body do
      audio("UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQAAAAA=", "audio/wav")
    end
  end

  tool :link, params: :Label, description: "A link to a resource the client can fetch" do
    body do |label|
      resource_link("contentkit://notes/#{label}", name: label, title: "Note #{label}", description: "A note by name",
                    mime_type: "text/plain", size: 120, audience: [:assistant])
    end
  end

  tool :embed, params: :Label, description: "A text resource and a binary resource, embedded in the result" do
    body do |label|
      [
        embedded_text("contentkit://readme/#{label}", "Hello, #{label}", mime_type: "text/markdown", audience: [:user, :assistant], priority: 0.25),
        embedded_blob("contentkit://blob", "aGk=", mime_type: "application/octet-stream")
      ]
    end
  end

  transport :stdio
end
