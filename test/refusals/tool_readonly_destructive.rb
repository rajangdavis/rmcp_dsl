# expect: `destructive:` and `idempotent:` only mean something when `read_only:` is false
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x", read_only: true, destructive: true do
    body do |text|
      text
    end
  end
  transport :stdio
end
