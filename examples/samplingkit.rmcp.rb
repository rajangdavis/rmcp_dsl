# typed: true
# samplingkit: a server that declares `feature :sampling` (deprecated by SEP-2577) and asks the client's LLM
# for a completion from a tool body. `sample(prompt, max_tokens: n, ...)` is a server-to-client request
# (`sampling/createMessage`): the body reads the assistant text, the model, the role and the nil-able
# stop_reason. Only a tool body may call it, and declaring the feature is what puts it in scope.
server "samplingkit", version: "0.1.0",
       instructions: "Call `complete` to ask the client's LLM for a completion." do
  feature :sampling

  params :SampleParams do
    field :prompt, :string, description: "The user prompt to send to the client's LLM"
    field :max_tokens, :i32, description: "The maximum number of tokens to generate"
  end

  tool :complete, params: :SampleParams, description: "Ask the client's LLM for a completion",
                  read_only: true, open_world: false do
    body do |prompt, max_tokens|
      answer = sample(prompt, max_tokens: max_tokens, system: "Answer in one short sentence.", temperature: 0.2, stop: ["STOP"])
      "model=#{answer.model} stop=#{answer.stop_reason || "-"} role=#{answer.role} text=#{answer.text || "-"}"
    end
  end

  transport :stdio
end
