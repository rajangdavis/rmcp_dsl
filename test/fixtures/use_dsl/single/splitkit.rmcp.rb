# The splitkit server in one file, the reference for split/splitkit.rmcp.rb (test/test_use_dsl.rb).
server "splitkit", version: "0.1.0" do
  setting :greeting, env: "SPLITKIT_GREETING", default: "hello"
  helper :shout, args: [:string], returns: :string do |text|
    "#{text.upcase}!"
  end
  params :Greet do
    field :name, :string, description: "Who to greet"
  end
  tool :greet, params: :Greet, description: "Greet someone loudly" do
    body do |name|
      "#{setting(:greeting)} #{shout(name)}"
    end
  end
  transport :stdio
end
