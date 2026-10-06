# typed: true
# elicitation: a tool body asks the client for input with `elicit(message, schema: {...})`. The call is a
# server-to-client request (`elicitation/create`); the body sees the client's action, accept / decline /
# cancel, and the JSON content it sent back (nil when there was none). Such a tool is compiled async and
# can fail, like one that sends progress.
server "elicitation", version: "0.1.0",
       instructions: "Ask the client for a name with `ask`, then report what it answered." do
  params :AskParams do
    field :question, :string, description: "What to ask the user", min_length: 1
  end

  tool :ask, params: :AskParams, description: "Ask the client a question and report its answer" do
    body do |question|
      answer = elicit(question, schema: {
        "type" => "object",
        "properties" => {
          "name" => { "type" => "string", "description" => "The user's name" }
        },
        "required" => ["name"]
      })
      answer.action + ":" + answer.content.to_s
    end
  end

  transport :stdio
end
