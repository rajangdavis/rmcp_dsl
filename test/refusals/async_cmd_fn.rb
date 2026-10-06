# expect: is not supported on a subprocess: cmd_fn and script_fn run a blocking
server "refuse", version: "0.1.0" do
  cmd_fn :up, program: "tr", argv: ["a-z", "A-Z"], args: [:string], returns: :string, pass: :stdin, async: true

  params :P do
    field :s, :string
  end

  tool :t, params: :P, description: "x" do
    body do |s|
      rust(:up, s)
    end
  end

  transport :stdio
end