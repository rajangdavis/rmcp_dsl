# expect: an async call inside a gsub block is not supported
server "refuse", version: "0.1.0" do
  rust_item <<~'RS'
    async fn up(s: &str) -> String { std::future::ready(()).await; s.to_uppercase() }
  RS
  rust_fn :up, args: [:string], returns: :string, async: true

  helper :shout, args: [:string], returns: :string do |s|
    rust(:up, s)
  end

  params :P do
    field :s, :string
  end

  tool :t, params: :P, description: "x" do
    body do |s|
      s.gsub(/\d+/) { |m| shout(m) }
    end
  end

  transport :stdio
end