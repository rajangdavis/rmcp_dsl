# expect: is not supported on a subprocess: cmd_fn and script_fn run a blocking
server "refuse", version: "0.1.0" do
  script_fn :echo, interpreter: "sh", code: "printf '%s' \"$1\"", args: [:string], returns: :string, async: true

  params :P do
    field :s, :string
  end

  tool :t, params: :P, description: "x" do
    body do |s|
      rust(:echo, s)
    end
  end

  transport :stdio
end