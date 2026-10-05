# typed: true
# Resource templates with RFC 6570 operators: {+path} (a value with slashes), {a,b} (several values), {x*} (a list)
# and {?q,limit} (optional query variables). Each placeholder's value is percent-decoded and checked before the body
# runs; a query variable that is not in the uri is nil in the body.
server "pathkit", version: "0.1.0", instructions: "Resources whose uris carry paths, pairs, lists and a query" do
  params :FilePath do
    field :path, :string, description: "A path, slashes included"
  end

  resource :file, uri: "pathkit://files/{+path}", params: :FilePath, title: "A file", mime_type: "text/plain" do
    body do |path|
      "contents of #{path}"
    end
  end

  params :Pair do
    field :left, :string
    field :right, :string
  end

  resource :pair, uri: "pathkit://pairs/{left,right}", params: :Pair, title: "A pair" do
    body do |left, right|
      "#{left}+#{right}"
    end
  end

  params :Tags do
    field :tags, :string_list, description: "Comma-separated tags"
  end

  resource :tagged, uri: "pathkit://tagged/{tags*}", params: :Tags, title: "Tagged" do
    body do |tags|
      "#{tags.size} tags: #{tags.join("|")}"
    end
  end

  params :Search do
    field :q, :string, optional: true, description: "What to look for"
    field :limit, :string, optional: true, description: "How many answers"
  end

  resource :search, uri: "pathkit://search{?q,limit}", params: :Search, title: "Search" do
    body do |q, limit|
      "q=#{q || "-"} limit=#{limit || "10"}"
    end
  end

  transport :stdio
end
