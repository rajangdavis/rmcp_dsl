# expect: got nil
server "t", version: "0.1.0" do
  params :P do
    field :n, :i64
  end

  tool :x, params: :P, description: "d" do
    body do |n|
      nil
    end
  end

  transport :stdio
end
