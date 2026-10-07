# expect: `allowed_hosts:` only applies to `transport :http`
server "t", version: "0.1.0" do
  params :P do
    field :s, :string
  end

  tool :x, params: :P, description: "d" do
    body do |s|
      s
    end
  end

  transport :stdio, allowed_hosts: ["example.com"]
end
