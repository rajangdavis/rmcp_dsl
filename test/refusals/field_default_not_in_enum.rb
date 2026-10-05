# expect: `default:` is not one of the `enum:` values
server "refuse", version: "0.1.0" do
  params :P do
    field :s, :string, default: "z", enum: ["a", "b"]
  end
  tool :t, params: :P, description: "x" do
    body do |s|
      "#{s}"
    end
  end
  transport :stdio
end
