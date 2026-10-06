# expect: declare `feature :logging` to use `log`
server "t", version: "0.1.0" do
  params :P do
    field :message, :string
  end

  tool :log_it, params: :P, description: "d" do
    body do |message|
      log(:info, message)
      "ok"
    end
  end

  transport :stdio
end
