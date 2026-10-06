# typed: true
# Settings: values the server reads from its environment when it starts. A required one that is missing stops the
# server with a message naming the variable (never its value); a secret can only be handed to a rust_fn or binding
# function, so a body cannot print or return it. Bodies read a setting with setting(:name).
server "configkit", version: "0.1.0", instructions: "Shows what the server was configured with, without its secret" do
  setting :api_key, env: "CONFIGKIT_API_KEY", secret: true, description: "the key the upstream API wants"
  setting :region, env: "CONFIGKIT_REGION", default: "eu-west", description: "where requests go"
  setting :label, env: "CONFIGKIT_LABEL", optional: true, description: "an optional display name"

  rust_item <<~'RS'
    fn key_length(key: &str) -> i64 {
        key.chars().count() as i64
    }
  RS
  rust_fn :key_length, args: [:string], returns: :i64

  params :Nothing do
    field :note, :string, optional: true, description: "ignored"
  end

  tool :describe, params: :Nothing, description: "The region, the label and how long the key is (the key itself stays private)" do
    body do
      "region #{setting(:region)}, label #{setting(:label) || "none"}, key of #{rust(:key_length, setting(:api_key))} characters"
    end
  end

  transport :stdio
end
