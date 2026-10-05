# expect: body must return a string, got T.nilable(Integer (i32)); use .to_s
server "refuse", version: "0.1.0" do
  params :P do
    field :limit, :i32, optional: true
  end
  tool :t, params: :P, description: "x" do
    body do |limit|
      limit
    end
  end
  transport :stdio
end
