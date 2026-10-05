# expect: `:system` is not one of :user :assistant
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  prompt :p, params: :P, description: "x" do
    message :system do |t|
      t
    end
  end
  transport :stdio
end
