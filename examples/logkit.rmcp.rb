# typed: true
# logkit: a server that declares `feature :logging` (deprecated by SEP-2577) and logs from a tool body.
# The declaration is what puts `log(...)` in scope, advertises the logging capability and answers
# `logging/setLevel`; without it the compiler refuses `log` and points at the declaration.
server "logkit", version: "0.1.0",
       instructions: "Call `log_info` or `log_warning` to emit one MCP log notification; `silence_log_info` and `restore_log_info` hide and show log_info at run time." do
  feature :logging

  params :LogParams do
    field :message, :string, description: "Text to log"
  end

  # A symbol level (`:info`).
  tool :log_info, params: :LogParams, description: "Emit an info log notification",
                  read_only: true, open_world: false do
    body do |message|
      log(:info, message)
      "logged at info"
    end
  end

  # A string level (`"warning"`), the other spelling the compiler accepts.
  tool :log_warning, params: :LogParams, description: "Emit a warning log notification",
                     read_only: true, open_world: false do
    body do |message|
      log("warning", message)
      "logged at warning"
    end
  end

  # Hide a tool at run time: log_info disappears from tools/list and further calls to it are refused
  # (invalid params) until restore_log_info shows it again. The server advertises tools/list_changed and
  # sends notifications/tools/list_changed; unlike logging, no `feature` declaration is needed, because
  # tool-list changes are a current capability.
  tool :silence_log_info, params: :LogParams, description: "Hide log_info from tools/list until restore_log_info runs",
                          read_only: true, open_world: false do
    body do |message|
      hide_tool(:log_info)
      "hidden log_info: #{message}"
    end
  end

  # The other half: show_tool(:log_info) puts it back and tells clients again.
  tool :restore_log_info, params: :LogParams, description: "Show log_info in tools/list again",
                          read_only: true, open_world: false do
    body do |message|
      show_tool(:log_info)
      "restored log_info: #{message}"
    end
  end

  transport :stdio
end
