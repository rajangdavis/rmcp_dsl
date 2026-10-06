# expect: is async and is part of a recursive helper cycle
server "refuse", version: "0.1.0" do
  rust_item <<~'RS'
    async fn fetch(s: &str) -> String { std::future::ready(()).await; s.to_string() }
  RS
  rust_fn :fetch, args: [:string], returns: :string, async: true

  params :P do
    field :s, :string
  end

  helper :again, args: [:string], returns: :string do |s|
    again(rust(:fetch, s))
  end

  tool :t, params: :P, description: "x" do
    body do |s|
      again(s)
    end
  end

  transport :stdio
end