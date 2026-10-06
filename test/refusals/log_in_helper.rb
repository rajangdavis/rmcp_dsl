# expect: `log` sends a logging notification, which only a tool body can do, not a helper `h` body
server "t", version: "0.1.0" do
  feature :logging

  helper :h, args: [:string], returns: :string do |s|
    log(:info, s)
    s
  end

  params :P do
    field :message, :string
  end

  tool :log_it, params: :P, description: "d" do
    body do |message|
      "#{h(message)}"
    end
  end

  transport :stdio
end
