fragment do
  # A fragment may include another; the path is relative to this file.
  use_dsl "params.rmcp.rb"

  tool :greet, params: :Greet, description: "Greet someone loudly" do
    body do |name|
      "#{setting(:greeting)} #{shout(name)}"
    end
  end
end
