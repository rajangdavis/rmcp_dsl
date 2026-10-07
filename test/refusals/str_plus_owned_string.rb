# expect: use interpolation or `.to_s`
server "t", version: "0.1.0" do
  params :P do
    field :name, :string
  end

  tool :x, params: :P, description: "d" do
    body do |name|
      "hello " + name
    end
  end

  transport :stdio
end
