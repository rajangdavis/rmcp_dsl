# typed: true
# Hooking in existing Rust: examples/rust/shout.rs becomes module `loud` in the crate.
server "hooked", version: "0.1.0" do
  rust_file "rust/shout.rs", as: :loud
  rust_fn :shout, from: :loud, args: [:string], returns: :string

  params :TextParams do
    field :text, :string
  end

  tool :shout, params: :TextParams, description: "Uppercase text and add an exclamation mark (existing Rust file)" do
    body do |text|
      rust(:shout, text)
    end
  end

  transport :stdio
end
