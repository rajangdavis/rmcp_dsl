# typed: true
# Paged lists: `page_size: 2` cuts tools/list, prompts/list, resources/list and resources/templates/list into pages of
# two; each page names the next one in `nextCursor`, and a cursor the server did not issue is invalid params.
server "pagekit", version: "0.1.0", page_size: 2, instructions: "Three of everything, two to a page" do
  params :Word do
    field :word, :string
  end

  params :Id do
    field :id, :string
  end

  tool :one, params: :Word, description: "Echo, first" do
    body { |word| "one #{word}" }
  end

  tool :two, params: :Word, description: "Echo, second" do
    body { |word| "two #{word}" }
  end

  tool :three, params: :Word, description: "Echo, third" do
    body { |word| "three #{word}" }
  end

  prompt :first, params: :Word, description: "A prompt, first" do
    body { |word| "first #{word}" }
  end

  prompt :second, params: :Word, description: "A prompt, second" do
    body { |word| "second #{word}" }
  end

  prompt :third, params: :Word, description: "A prompt, third" do
    body { |word| "third #{word}" }
  end

  resource :a, uri: "pagekit://a", title: "A" do
    body { "a" }
  end

  resource :b, uri: "pagekit://b", title: "B" do
    body { "b" }
  end

  resource :c, uri: "pagekit://c", title: "C" do
    body { "c" }
  end

  resource :x, uri: "pagekit://x/{id}", params: :Id, title: "X" do
    body { |id| "x #{id}" }
  end

  resource :y, uri: "pagekit://y/{id}", params: :Id, title: "Y" do
    body { |id| "y #{id}" }
  end

  resource :z, uri: "pagekit://z/{id}", params: :Id, title: "Z" do
    body { |id| "z #{id}" }
  end

  transport :stdio
end
