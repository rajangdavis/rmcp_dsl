# typed: true
# guide: a server with no tools at all, only a prompt and a resource. Clients that list tools see none;
# they can read the resource and offer the prompt.
server "guide", version: "0.1.0", instructions: "Read the intro resource first, then ask for an explanation.",
       title: "Guide", description: "A tiny guide with one prompt and one resource", website_url: "https://example.com/guide",
       icon: "https://example.com/guide.png" do
  params :TopicParams do
    field :topic, :string, description: "What you want explained"
  end

  # An async Rust function injected into the crate: `stamp` is a real `async fn` (it awaits), and
  # `rust_fn ... async: true` declares that. `decorate` is a helper that calls it, so the helper is async
  # too (async is inferred, not written on the caller); the prompt and resource bodies below await it.
  rust_item <<~'RS'
    async fn stamp(label: &str) -> String {
        std::future::ready(()).await;
        format!("[{label}]")
    }
  RS
  rust_fn :stamp, args: [:string], returns: :string, async: true

  helper :decorate, args: [:string], returns: :string do |s|
    "<<#{rust(:stamp, s)}>>"
  end

  # Two messages: the first sets the scene as the assistant, the second is the question.
  prompt :explain, params: :TopicParams, description: "Ask for an explanation of a topic", title: "Explain a topic",
                   icon: "https://example.com/explain.png" do
    message :assistant do
      "I am ready to explain things using the guide."
    end

    message :user do |topic|
      "Explain #{decorate(topic)} using the guide."
    end
  end

  # A prompt message, like a tool result, may return content blocks instead of a string.
  prompt :illustrated, params: :TopicParams, description: "Ask for an illustrated explanation" do
    message :user do |topic|
      "Show me #{topic}."
    end

    message :assistant do |topic|
      [
        text("An illustration of #{topic}."),
        image("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==", "image/png"),
        embedded_text("guide://intro", "The guide introduction.", mime_type: "text/markdown")
      ]
    end
  end

  resource :intro, uri: "guide://intro", title: "Guide introduction", description: "Start here",
                   mime_type: "text/markdown", icon: "https://example.com/intro.png",
                   audience: ["user", "assistant"], priority: 0.5 do
    body do
      decorate("# Guide") + "\n\nStart with the basics."
    end
  end

  # A resource body may return a blob of base64 text instead of a string; the resource MIME type is its default.
  resource :logo, uri: "guide://logo", title: "Guide logo", description: "A one-pixel PNG",
                   mime_type: "image/png" do
    body do
      blob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
    end
  end

  # A body may return several contents in one read: here a text part and a blob part.
  resource :chapter, uri: "guide://chapter", title: "Guide chapter", description: "Text with its diagram",
                     mime_type: "text/markdown" do
    body do
      [
        text("# Chapter 1\n\nSee the diagram."),
        blob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==", mime_type: "image/png")
      ]
    end
  end

  transport :stdio
end
