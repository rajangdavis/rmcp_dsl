# expect: `page_size:` is how many items one page
server "refuse", version: "0.1.0", page_size: 0 do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      t
    end
  end
  transport :stdio
end
