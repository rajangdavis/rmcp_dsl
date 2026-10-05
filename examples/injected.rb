# typed: true
# Proof of tier 2 (injected Rust): a crate, a function written in Rust, and a typed call from Ruby.
server "injected", version: "0.1.0" do
  rust_crate "heck", "0.5"
  rust_item <<~'RS'
    fn to_snake(s: &str) -> String {
        use heck::ToSnakeCase;
        s.to_snake_case()
    }
  RS
  rust_fn :to_snake, args: [:string], returns: :string

  params :TextParams do
    field :text, :string
  end

  tool :snake_case, params: :TextParams, description: "Convert text to snake_case (injected Rust: the heck crate)" do
    body do |text|
      rust(:to_snake, text)
    end
  end

  transport :stdio
end
