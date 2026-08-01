defmodule SymphonyElixir.CodexActivityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.Activity

  @timestamp ~U[2026-07-31 08:16:41Z]

  defp notification(method, params, timestamp \\ @timestamp) do
    %{
      event: :notification,
      timestamp: timestamp,
      payload: %{"method" => method, "params" => params}
    }
  end

  test "streaming deltas never become the reported activity" do
    noisy = [
      notification("item/reasoning/textDelta", %{"delta" => "considering the diff"}),
      notification("item/reasoning/summaryTextDelta", %{"summaryText" => "step one"}),
      notification("item/agentMessage/delta", %{"delta" => "partial answer"}),
      notification("item/fileChange/outputDelta", %{"outputDelta" => "patching"})
    ]

    Enum.each(noisy, fn update ->
      refute Map.has_key?(Activity.observe(update), :activity)
      refute Map.has_key?(Activity.observe(update), :trail)
    end)
  end

  test "command output is captured as output rather than as an activity" do
    update = notification("item/commandExecution/outputDelta", %{"outputDelta" => "(node:83011) ExperimentalWarning"})

    effects = Activity.observe(update)

    assert effects == %{stdout: "(node:83011) ExperimentalWarning"}
  end

  test "a started command reports the command being run" do
    update =
      notification("item/started", %{
        "item" => %{"id" => "exec-1", "type" => "commandExecution", "command" => ["pnpm", "vitest", "run"]}
      })

    assert %{activity: activity} = Activity.observe(update)
    assert activity.kind == :command
    assert activity.label == "Running command"
    assert activity.detail == "pnpm vitest run"
    assert activity.since == @timestamp
  end

  test "a non-zero exit is recorded as a failure in the trail" do
    update =
      notification("item/completed", %{
        "item" => %{"id" => "exec-2", "type" => "commandExecution", "command" => "mix dialyzer", "exitCode" => 1}
      })

    assert %{trail: trail} = Activity.observe(update)
    assert trail.kind == :failed
    assert trail.title == "mix dialyzer"
    assert trail.meta == "exit 1"
  end

  test "plan updates carry step progress" do
    update =
      notification("turn/plan/updated", %{
        "plan" => [
          %{"step" => "read review", "status" => "completed"},
          %{"step" => "add tests", "status" => "in_progress"},
          %{"step" => "open PR", "status" => "pending"}
        ]
      })

    assert %{plan: plan} = Activity.observe(update)
    assert plan.completed == 1
    assert plan.total == 3
    assert Enum.map(plan.steps, & &1.text) == ["read review", "add tests", "open PR"]
  end

  test "diff updates count changed lines without counting file headers" do
    diff = "+++ b/a.ts\n--- a/a.ts\n+added one\n+added two\n-removed one\n context"

    assert %{diff: %{files: 1, added: 2, removed: 1}} =
             Activity.observe(notification("turn/diff/updated", %{"diff" => diff}))
  end

  test "approval requests report the session as blocked" do
    update = notification("item/commandExecution/requestApproval", %{"parsedCmd" => "git push --force-with-lease"})

    assert %{activity: activity} = Activity.observe(update)
    assert activity.kind == :awaiting_approval
    assert activity.detail == "git push --force-with-lease"
    assert Activity.blocked?(activity)
  end

  test "repeating the same activity preserves when it started" do
    started =
      notification("item/started", %{"item" => %{"id" => "exec-1", "type" => "commandExecution", "command" => "mix test"}})

    %{activity: first} = Activity.observe(started)
    %{activity: repeat} = Activity.observe(%{started | timestamp: ~U[2026-07-31 08:20:00Z]})

    assert Activity.advance(first, repeat).since == @timestamp
  end

  test "an inferred activity never clears a session that needs a human" do
    %{activity: blocked} = Activity.observe(notification("item/commandExecution/requestApproval", %{"parsedCmd" => "rm -rf build"}))

    %{activity: settled} =
      Activity.observe(notification("item/completed", %{"item" => %{"id" => "other", "type" => "commandExecution"}}))

    assert Activity.advance(blocked, settled) == blocked
  end

  test "an announced activity does clear a blocked session" do
    %{activity: blocked} = Activity.observe(notification("item/commandExecution/requestApproval", %{"parsedCmd" => "rm -rf build"}))

    %{activity: resumed} =
      Activity.observe(notification("item/started", %{"item" => %{"id" => "exec-9", "type" => "commandExecution", "command" => "rm -rf build"}}))

    assert Activity.advance(blocked, resumed).kind == :command
  end

  test "unrecognized events produce no effects" do
    assert Activity.observe(notification("account/updated", %{"authMode" => "apiKey"})) == %{}
    assert Activity.observe(notification("codex/event/mcp_startup_complete", %{})) == %{}
    assert Activity.observe(%{event: :notification, timestamp: @timestamp, payload: "not json"}) == %{}
    assert Activity.observe(%{event: :notification, timestamp: @timestamp, payload: %{"params" => %{}}}) == %{}
    assert Activity.observe(%{}) == %{}
    assert Activity.observe(nil) == %{}
  end

  test "session and turn lifecycle events are reported" do
    lifecycle = [
      {%{event: :session_started, timestamp: @timestamp}, :starting, "Session started"},
      {%{event: :turn_input_required, timestamp: @timestamp}, :awaiting_input, "Turn blocked waiting for input"},
      {%{event: :turn_completed, timestamp: @timestamp}, :turn_done, "Turn completed"},
      {%{event: :turn_cancelled, timestamp: @timestamp}, :failed, "Turn cancelled"}
    ]

    Enum.each(lifecycle, fn {update, kind, title} ->
      assert %{activity: activity, trail: trail} = Activity.observe(update)
      assert activity.kind == kind
      assert trail.title == title
    end)

    assert %{activity: %{kind: :thinking}, trail: %{title: "Turn started"}} =
             Activity.observe(notification("turn/started", %{}, @timestamp))
  end

  test "failures surface the underlying error message" do
    failed = %{
      event: :turn_failed,
      timestamp: @timestamp,
      payload: %{"params" => %{"error" => %{"message" => "worker lost\n  connection"}}}
    }

    assert %{activity: activity, trail: trail} = Activity.observe(failed)
    assert activity.kind == :failed
    assert activity.detail == "worker lost connection"
    assert trail.title == "worker lost connection"
    assert trail.meta == "turn failed"

    assert %{activity: %{kind: :failed, detail: nil}} =
             Activity.observe(%{event: :startup_failed, timestamp: @timestamp, payload: %{}})
  end

  test "approval and input requests carry what is being asked" do
    assert %{activity: %{kind: :awaiting_approval, detail: "3 files"}} =
             Activity.observe(notification("item/fileChange/requestApproval", %{"fileChangeCount" => 3}, @timestamp))

    assert %{activity: %{kind: :awaiting_approval, detail: nil}} =
             Activity.observe(notification("item/fileChange/requestApproval", %{}, @timestamp))

    assert %{activity: %{kind: :awaiting_input, detail: "Continue?"}} =
             Activity.observe(notification("item/tool/requestUserInput", %{"question" => "Continue?"}, @timestamp))

    assert %{activity: %{kind: :awaiting_input, detail: nil}} =
             Activity.observe(notification("tool/requestUserInput", %{"prompt" => "   "}, @timestamp))

    assert %{activity: %{kind: :awaiting_approval, detail: "rm -rf tmp"}} =
             Activity.observe(%{
               event: :approval_required,
               timestamp: @timestamp,
               payload: %{"params" => %{"command" => "rm -rf tmp"}}
             })
  end

  test "dynamic tool calls are reported by name" do
    assert %{activity: %{kind: :tool, detail: "linear_graphql"}} =
             Activity.observe(notification("item/tool/call", %{"tool" => "linear_graphql"}, @timestamp))

    assert %{trail: %{kind: :tool, title: "linear_graphql", meta: "Called"}} =
             Activity.observe(%{
               event: :tool_call_completed,
               timestamp: @timestamp,
               payload: %{"params" => %{"tool" => "linear_graphql"}}
             })

    assert %{trail: %{title: "tool", meta: "Failed calling"}} =
             Activity.observe(%{event: :tool_call_failed, timestamp: @timestamp, payload: %{"params" => %{}}})
  end

  test "each item type maps onto a distinct activity" do
    types = [
      {%{"id" => "i1", "type" => "reasoning"}, :thinking, nil},
      {%{"id" => "i2", "type" => "agentMessage"}, :writing, nil},
      {%{"id" => "i3", "type" => "mcpToolCall", "tool" => "search"}, :tool, "search"},
      {%{"id" => "i4", "type" => "webSearch", "query" => "elixir genserver"}, :search, "elixir genserver"},
      {%{"id" => "i5", "type" => "fileChange", "changes" => [%{"path" => "lib/a.ex"}]}, :edit, "a.ex"}
    ]

    Enum.each(types, fn {item, kind, detail} ->
      assert %{activity: activity} = Activity.observe(notification("item/started", %{"item" => item}, @timestamp))
      assert activity.kind == kind
      assert activity.detail == detail
    end)

    assert Activity.observe(notification("item/started", %{"item" => %{"type" => "todoList"}}, @timestamp)) == %{}
    assert Activity.observe(notification("item/completed", %{"item" => %{"type" => "todoList"}}, @timestamp)) == %{}

    # Lifecycle events whose item is missing or malformed must degrade quietly
    # rather than crash the orchestrator that folds them in.
    assert Activity.observe(notification("item/started", %{}, @timestamp)) == %{}
    assert Activity.observe(notification("item/started", %{"item" => "not a map"}, @timestamp)) == %{}
  end

  test "completed items describe what was produced" do
    completions = [
      {%{"type" => "fileChange", "files" => ["lib/a.ex", "lib/b.ex", "lib/c.ex"]}, "a.ex +2 more", nil},
      {%{"type" => "fileChange", "fileChangeCount" => 4}, "4 files", nil},
      {%{"type" => "fileChange"}, "File changes", nil},
      {%{"type" => "fileChange", "changes" => [%{"unexpected" => true}, 42]}, "File changes", nil},
      {%{"type" => "fileChange", "changes" => ["lib/only.ex"], "additions" => 84, "deletions" => 12}, "only.ex", "+84 −12"},
      {%{"type" => "fileChange", "changes" => ["lib/only.ex"], "additions" => 84}, "only.ex", "+84"},
      {%{"type" => "fileChange", "changes" => ["lib/only.ex"], "deletions" => 12}, "only.ex", "−12"},
      {%{"type" => "commandExecution"}, "a command", nil},
      {%{"type" => "commandExecution", "command" => "mix test", "exitCode" => 0}, "mix test", "exit 0"},
      {%{"type" => "mcpToolCall"}, "a tool", nil},
      {%{"type" => "webSearch"}, "a web search", nil},
      {%{"type" => "agentMessage", "message" => "done"}, "done", nil}
    ]

    Enum.each(completions, fn {item, title, meta} ->
      assert %{trail: trail} = Activity.observe(notification("item/completed", %{"item" => item}, @timestamp))
      assert trail.title == title
      assert trail.meta == meta
    end)

    # An agent message with nothing quotable is not worth a trail entry.
    assert Activity.observe(notification("item/completed", %{"item" => %{"type" => "agentMessage"}}, @timestamp)) == %{}

    assert Activity.observe(notification("item/completed", %{"item" => %{"type" => "agentMessage", "text" => "  \n\t "}}, @timestamp)) ==
             %{}
  end

  # Agent messages are the one kind kept at length, because the UI expands them
  # and a message truncated to a headline would expand into the same headline.
  test "agent messages keep their paragraphs and are capped well beyond one line" do
    body = String.duplicate("a", 300) <> "\n\n\n\nsecond    paragraph"

    assert %{trail: trail} =
             Activity.observe(notification("item/completed", %{"item" => %{"type" => "agentMessage", "text" => body}}, @timestamp))

    assert String.contains?(trail.title, "\n\nsecond paragraph")
    refute String.contains?(trail.title, "\n\n\n")
    assert String.length(trail.title) > 160

    long = String.duplicate("b", 2_500)

    assert %{trail: %{title: capped}} =
             Activity.observe(notification("item/completed", %{"item" => %{"type" => "agentMessage", "text" => long}}, @timestamp))

    assert String.length(capped) == 2_000
    assert String.ends_with?(capped, "…")
  end

  test "commands are normalized regardless of how they are expressed" do
    shapes = [
      {%{"command" => "mix test"}, "mix test"},
      {%{"command" => ["mix", "test", "--cover"]}, "mix test --cover"},
      {%{"command" => %{"cmd" => "mix", "args" => ["test"]}}, "mix test"},
      {%{"command" => %{"command" => "mix"}}, "mix"},
      {%{"command" => %{"args" => ["test"]}}, nil},
      {%{"command" => []}, nil},
      {%{"command" => 42}, nil}
    ]

    Enum.each(shapes, fn {fields, expected} ->
      item = Map.merge(%{"id" => "exec", "type" => "commandExecution"}, fields)

      assert %{activity: %{detail: ^expected}} =
               Activity.observe(notification("item/started", %{"item" => item}, @timestamp))
    end)
  end

  test "long details are truncated rather than allowed to break the layout" do
    command = String.duplicate("a", 400)
    item = %{"id" => "exec", "type" => "commandExecution", "command" => command}

    assert %{activity: %{detail: detail}} =
             Activity.observe(notification("item/started", %{"item" => item}, @timestamp))

    assert String.length(detail) == 160
    assert String.ends_with?(detail, "…")
  end

  test "plans accept both structured steps and bare strings" do
    assert %{plan: plan} =
             Activity.observe(notification("turn/plan/updated", %{"steps" => ["first", %{"title" => "second"}, 7]}, @timestamp))

    assert Enum.map(plan.steps, & &1.text) == ["first", "second", ""]
    assert plan.completed == 0

    assert Activity.observe(notification("turn/plan/updated", %{"plan" => "not a list"}, @timestamp)) == %{}
  end

  test "empty diffs and empty output are ignored" do
    assert Activity.observe(notification("turn/diff/updated", %{"diff" => ""}, @timestamp)) == %{}
    assert Activity.observe(notification("item/commandExecution/outputDelta", %{}, @timestamp)) == %{}
  end

  # Deployments on the older wrapper protocol report command lifecycle through
  # codex/event/* instead of item/*; both must produce an activity.
  test "the legacy wrapper protocol is understood" do
    legacy = fn suffix, msg -> notification("codex/event/#{suffix}", %{"msg" => msg}, @timestamp) end

    assert %{activity: %{kind: :command, detail: "rg privacy src/"}, trail: %{title: "rg privacy src/"}} =
             Activity.observe(legacy.("exec_command_begin", %{"command" => ["rg", "privacy", "src/"]}))

    assert %{activity: %{kind: :command, detail: nil}, trail: %{title: "a command"}} =
             Activity.observe(legacy.("exec_command_begin", %{}))

    assert %{trail: %{kind: :command, title: "Command finished", meta: "exit 0"}} =
             Activity.observe(legacy.("exec_command_end", %{"exit_code" => 0}))

    assert %{trail: %{kind: :failed, title: "Command finished", meta: "exit 2"}} =
             Activity.observe(legacy.("exec_command_end", %{"exitCode" => 2}))

    assert %{trail: %{title: "Command finished", meta: nil}} = Activity.observe(legacy.("exec_command_end", %{}))

    assert %{stdout: "building"} = Activity.observe(legacy.("exec_command_output_delta", %{"chunk" => "building"}))
    assert Activity.observe(legacy.("exec_command_output_delta", %{})) == %{}

    assert %{diff: %{added: 1}} = Activity.observe(legacy.("turn_diff", %{"unified_diff" => "+one"}))
    assert Activity.observe(legacy.("turn_diff", %{})) == %{}
  end

  test "payloads with atom keys are read the same as decoded json" do
    update = %{
      event: :notification,
      timestamp: @timestamp,
      payload: %{method: "item/started", params: %{item: %{id: "exec-1", type: "commandExecution", command: "mix test"}}}
    }

    assert %{activity: %{kind: :command, detail: "mix test"}} = Activity.observe(update)
  end

  test "an update without a decoded payload falls back to its raw form" do
    assert Activity.observe(%{event: :notification, timestamp: @timestamp, raw: "{\"method\":\"turn/started\"}"}) == %{}
  end

  test "the initial activity reports startup and is not blocking" do
    activity = Activity.initial(@timestamp)

    assert activity.kind == :starting
    assert activity.since == @timestamp
    refute Activity.blocked?(activity)
    refute Activity.blocked?(nil)
  end

  test "advancing from no activity adopts the incoming one" do
    %{activity: incoming} = Activity.observe(notification("turn/started", %{}, @timestamp))

    assert Activity.advance(nil, incoming) == incoming
  end
end
