# typed: true
# A sync-only fixture for the async golden test: every construct here compiles without an await,
# so its emitted Rust must stay byte for byte the same across the async inference/closure work
# (a sync helper, a rust_fn call, a list map, a gsub block, a fallible tool body, a prompt body
# and a resource body).
server "golden", version: "0.1.0" do
  rust_item <<~'RS'
    fn shout(s: &str) -> String { s.to_uppercase() }
  RS
  rust_fn :shout, args: [:string], returns: :string

  params :GoldenParams do
    field :text, :string
    field :xs, :string_list
  end

  params :AskParams do
    field :text, :string
  end

  helper :wrap, args: [:string], returns: :string do |s|
    "[#{s}]"
  end

  tool :run, params: :GoldenParams, description: "the golden sync tool" do
    body do |text, xs|
      n = text.to_i
      loud = rust(:shout, text)
      joined = xs.map { |x| wrap(x) }.join(",")
      text.gsub(/\d+/) { |m| wrap(m) } + " " + loud + " " + joined + " n=#{n}"
    end
  end

  prompt :ask, params: :AskParams, description: "ask" do
    message :user do |text|
      wrap(text)
    end
  end

  resource :doc, uri: "golden://doc" do
    body do
      text("hello")
    end
  end

  transport :stdio
end
