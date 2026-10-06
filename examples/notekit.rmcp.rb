# typed: true
# notekit: tool annotations, field constraints and optional fields. The annotations tell a client which
# tools are safe to call without asking; the constraints go into the tool's JSON schema and are also
# enforced by the generated server; an optional field is nil-able in the body (`limit || 10`).
server "notekit", version: "0.1.0",
       instructions: "Search the notes with `search` (all arguments but `query` are optional). Delete one with `delete_note`, which cannot be undone." do
  params :SearchParams do
    field :query, :string, description: "Words to look for", min_length: 1, max_length: 40
    field :limit, :i32, description: "Maximum results", optional: true, min: 1, max: 50
    field :kind, :string, description: "Which notes to search", optional: true, enum: ["all", "recent", "pinned"]
    field :tag, :string, description: "Only notes with this tag", optional: true, pattern: "^[a-z][a-z0-9-]*$"
    field :weight, :f64, description: "Ranking weight", optional: true, min: 0.5, max: 2.0
    field :exact, :bool, description: "Match whole words only", optional: true
  end

  params :DeleteParams do
    field :id, :i32, description: "Note id", min: 1
  end

  tool :search, params: :SearchParams, description: "Search the notes (pretend)",
                title: "Search notes", read_only: true, open_world: false, icon: "https://example.com/search.png",
                meta: { "com.example/tier" => "free", "com.example/limits" => { "calls" => 100, "burst" => 5 } } do
    body do |query, limit, kind, tag, weight, exact|
      "#{query}|#{limit || 10}|#{kind || "all"}|#{tag || "-"}|#{(weight || 1.0) > 1.5 ? "heavy" : "normal"}|#{exact || false}"
    end
  end

  tool :delete_note, params: :DeleteParams, description: "Delete a note (pretend)",
                     title: "Delete note", destructive: true, idempotent: true do
    body do |id|
      "deleted #{id}"
    end
  end

  params :ContextParams do
    field :echo, :string, description: "Text to echo back", optional: true
  end

  # A tool body may read the MCP request it is answering: the client, the negotiated protocol version, the
  # request id, the progress token and the cancellation flag. It may also send progress, which the e2e drives
  # with a token in `_meta`. The e2e asserts what the client sent and what the tool sent back.
  tool :context, params: :ContextParams, description: "Report the calling client and the protocol version",
                 title: "Request context", read_only: true, open_world: false do
    body do |echo|
      progress(1, total: 2, message: "half way")
      "client=#{client_name || "unknown"} version=#{client_version || "unknown"} protocol=#{protocol_version || "unknown"} request=#{request_id} progress=#{progress_token || "none"} cancelled=#{cancelled?} echo=#{echo || "none"}"
    end
  end

  # A helper used only by `complete:` still counts as used: it backs the topic argument's completion.
  helper :topic_choices, args: [:string], returns: :string_list do |typed|
    ["cats", "cooking", "rust", "gardening"].select { |t| t.start_with?(typed) }
  end

  params :SummarizeParams do
    field :topic, :string, description: "What to summarize", min_length: 1, complete: :topic_choices
    field :style, :string, description: "How much detail", optional: true, enum: ["short", "detailed"]
  end

  # A prompt is a template the client can offer the user; its arguments are strings, like a tool's fields.
  prompt :summarize, params: :SummarizeParams, description: "Ask for a summary of the notes about a topic",
                     meta: { "com.example/audience" => ["students", "editors"] } do
    body do |topic, style|
      "Summarize my notes about #{topic} in a #{style || "short"} style."
    end
  end

  # A resource is readable text at a URI; the body runs on every read.
  resource :guide, uri: "notekit://guide", title: "Notekit guide", description: "How the notes are organised",
                   mime_type: "text/markdown", size: 47, meta: { "com.example/maintained" => true, "com.example.mcp/not-reserved" => "ok" } do
    body do
      "# Notekit\n\nNotes have a title, a body and tags."
    end
  end

  params :NoteParams do
    field :id, :string, description: "Note id", pattern: "^[0-9]+$"
  end

  params :ListParams do
    field :kind, :string, description: "Which list", enum: ["recent", "pinned"]
  end

  # A uri with {placeholders} is a resource template: the client fills them in and reads the result. Each value is
  # checked against the field it names, and a `raise` here means the note does not exist.
  resource :note, uri: "notekit://notes/{id}", params: :NoteParams, title: "A note", description: "One note by id",
                  mime_type: "text/plain", meta: { "com.example/ttl" => 60 } do
    body do |id|
      raise "no note with id #{id}" if id == "404"
      "Note #{id}: remember the milk"
    end

    # A `complete` block answers for every argument of this template; it offers the note ids that exist.
    complete do |arg, typed|
      ids = ["1", "2", "3", "42"]
      ids.select { |n| n.start_with?(typed) && arg == "id" }
    end
  end

  resource :list, uri: "notekit://lists/{kind}", params: :ListParams, title: "A list of notes",
                  mime_type: "text/plain" do
    body do |kind|
      "The #{kind} notes"
    end
  end

  transport :stdio
end
