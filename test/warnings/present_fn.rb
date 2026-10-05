server "t", version: "0.1.0" do
  rust_file "rust/m.rs", as: :m
  rust_fn :here, from: :m, args: [:string], returns: :string

  params :P do
    field :text, :string
  end

  tool :x, params: :P, description: "d" do
    body do |text|
      rust(:here, text)
    end
  end

  transport :stdio
end
