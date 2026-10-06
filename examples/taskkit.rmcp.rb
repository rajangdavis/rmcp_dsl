# typed: true
# Tasks (the io.modelcontextprotocol/tasks extension): a tool declared with `task: true` returns a task handle to a
# client that declared the extension, and the client polls tasks/get for the result. The server decides per request;
# a client that did not declare the extension, and every other tool, gets the plain result. The body is the same.
server "taskkit", version: "0.1.0", instructions: "slow runs as a task for clients that support tasks; quick never does" do
  rust_item <<~'RS'
    fn nap(ms: i64) -> String {
        std::thread::sleep(std::time::Duration::from_millis(ms as u64));
        format!("slept {ms} ms")
    }
  RS
  rust_fn :nap, args: [:i64], returns: :string

  params :Nap do
    field :ms, :i64, min: 0, max: 5000, description: "How long to sleep, in milliseconds"
  end

  tool :slow, params: :Nap, description: "Sleep, then say how long (a task for clients that support them)",
              task: true, task_ttl_ms: 60_000, task_poll_ms: 100 do
    body do |ms|
      rust(:nap, ms)
    end
  end

  tool :quick, params: :Nap, description: "Sleep, then say how long (always answers directly)" do
    body do |ms|
      rust(:nap, ms)
    end
  end

  transport :stdio
end
