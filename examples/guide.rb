# typed: true
# guide: a server with no tools at all, only a prompt and a resource. Clients that list tools see none;
# they can read the resource and offer the prompt.
server "guide", version: "0.1.0", instructions: "Read the intro resource first, then ask for an explanation.",
       title: "Guide", description: "A tiny guide with one prompt and one resource", website_url: "https://example.com/guide",
       icon: "https://example.com/guide.png" do
  params :TopicParams do
    field :topic, :string, description: "What you want explained"
  end

  # Two messages: the first sets the scene as the assistant, the second is the question.
  prompt :explain, params: :TopicParams, description: "Ask for an explanation of a topic", title: "Explain a topic",
                   icon: "https://example.com/explain.png" do
    message :assistant do
      "I am ready to explain things using the guide."
    end

    message :user do |topic|
      "Explain #{topic} using the guide."
    end
  end

  resource :intro, uri: "guide://intro", title: "Guide introduction", description: "Start here",
                   mime_type: "text/markdown", icon: "https://example.com/intro.png",
                   audience: ["user", "assistant"], priority: 0.5 do
    body do
      "# Guide\n\nStart with the basics."
    end
  end

  transport :stdio
end
