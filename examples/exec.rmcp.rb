# typed: true
# Subprocess escape hatches: a fixed command (cmd_fn) and an inline script (script_fn).
# Arguments reach the program as argv entries or stdin, never as shell text.
server "execdemo", version: "0.1.0" do
  cmd_fn :run_upper, program: "tr", argv: ["a-z", "A-Z"], args: [:string], returns: :string, pass: :stdin

  script_fn :run_echo, interpreter: "sh", args: [:string], returns: :string, code: <<~'SH'
    printf '%s' "$1"
  SH

  # Failure paths: each of these must come back as text starting with "error:".
  cmd_fn :run_missing, program: "definitely-not-a-real-program", args: [:string], returns: :string

  script_fn :run_fails, interpreter: "sh", args: [:string], returns: :string, code: <<~'SH'
    echo boom >&2
    exit 3
  SH

  script_fn :run_sleeps, interpreter: "sh", args: [:string], returns: :string, code: <<~'SH'
    sleep 30
  SH

  script_fn :run_floods, interpreter: "sh", args: [:string], returns: :string, code: <<~'SH'
    head -c 2000000 /dev/zero | tr '\0' a
  SH

  params :TextParams do
    field :text, :string
  end

  tool :upper, params: :TextParams, description: "Uppercase text with tr (text goes in on stdin)" do
    body do |text|
      rust(:run_upper, text)
    end
  end

  tool :echo, params: :TextParams, description: "Return the text unchanged through sh (checks arguments stay data)" do
    body do |text|
      rust(:run_echo, text)
    end
  end

  tool :missing, params: :TextParams, description: "Runs a program that does not exist (error path)" do
    body do |text|
      rust(:run_missing, text)
    end
  end

  tool :fails, params: :TextParams, description: "Runs a script that exits with status 3 (error path)" do
    body do |text|
      rust(:run_fails, text)
    end
  end

  tool :sleeps, params: :TextParams, description: "Runs a script that outlives the 10 s timeout (error path)" do
    body do |text|
      rust(:run_sleeps, text)
    end
  end

  tool :floods, params: :TextParams, description: "Runs a script that prints 2 MB (error path)" do
    body do |text|
      rust(:run_floods, text)
    end
  end

  transport :stdio
end
