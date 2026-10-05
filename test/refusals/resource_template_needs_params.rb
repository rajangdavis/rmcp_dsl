# expect: add `params: :SomeParams` with a field for each
server "refuse", version: "0.1.0" do
  params :P do
    field :id, :string
  end
  resource :r, uri: "x://a/{id}" do
    body do |id|
      "text#{id}"
    end
  end
  transport :stdio
end
