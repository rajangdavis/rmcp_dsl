# expect: `log` is reserved; pick another helper name
server "t", version: "0.1.0" do
  helper :log, args: [], returns: :string do
    "x"
  end

  params :P do
    field :message, :string
  end

  tool :log_it, params: :P, description: "d" do
    body do |message|
      message
    end
  end

  transport :stdio
end
