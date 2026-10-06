# typed: true
# Resource subscriptions and change notifications: a tool says which resources it changes (`updates:`) or that it adds
# or removes some (`resource_list_changed:`), and once it succeeds the clients that asked are told. A client on protocol
# 2026-07-28 asks over a subscriptions/listen stream, an earlier one with resources/subscribe; the server serves both.
server "livekit", version: "0.1.0", instructions: "edit changes a note, add changes the list of resources" do
  resource :guide, uri: "livekit://guide", title: "Guide", mime_type: "text/plain" do
    body do
      "livekit notes"
    end
  end

  params :NoteId do
    field :id, :string, description: "A note number", pattern: "^[0-9]+$"
  end

  resource :note, uri: "livekit://notes/{id}", params: :NoteId, title: "A note", mime_type: "text/plain" do
    body do |id|
      "note #{id}"
    end
  end

  tool :edit, params: :NoteId, description: "Pretend to edit a note: its resource and the guide have changed",
              updates: ["livekit://notes/{id}", "livekit://guide"] do
    body do |id|
      "edited #{id}"
    end
  end

  tool :add, params: :NoteId, description: "Pretend to add a note: the list of resources has changed", resource_list_changed: true do
    body do |id|
      "added #{id}"
    end
  end

  transport :stdio
end
