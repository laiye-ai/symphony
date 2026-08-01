defmodule SymphonyElixir.Codex.Activity do
  @moduledoc """
  Derives what a Codex session is doing from its app-server event stream.

  The orchestrator keeps one "last event" slot per running issue, so whatever
  arrived most recently wins. Because the overwhelming majority of app-server
  traffic is high-frequency streaming deltas, that slot is almost always noise
  (`item/reasoning/textDelta`, subprocess stdout) rather than something an
  operator can act on.

  This module splits the stream by intent instead:

    * *activity* events -- item lifecycle, approval requests, turn boundaries --
      describe what the session is doing and may replace the current activity;
    * *progress* events -- streaming deltas -- carry no semantics but prove the
      session is alive, so callers use them only to refresh the heartbeat;
    * *detail* events -- plan and diff updates -- accumulate alongside the
      activity without replacing it.

  `observe/1` returns only the effects an event actually implies, so callers
  merge rather than overwrite. Every event refreshes the heartbeat regardless of
  what it returns here; liveness is the caller's concern.
  """

  @type kind ::
          :starting
          | :thinking
          | :command
          | :edit
          | :writing
          | :tool
          | :search
          | :awaiting_approval
          | :awaiting_input
          | :turn_done
          | :failed

  @type t :: %{
          kind: kind(),
          label: String.t(),
          detail: String.t() | nil,
          item_id: String.t() | nil,
          since: DateTime.t() | nil,
          soft: boolean()
        }

  @typedoc """
  One closed event.

  `title` is the subject -- the command, the message, the path. `meta` is the
  small structured fact that belongs to that kind of event (an exit code, a line
  count) and is nil whenever the payload did not actually carry one, so the UI
  never has to invent precision it was not given.
  """
  @type trail_entry :: %{
          at: DateTime.t() | nil,
          kind: kind(),
          title: String.t(),
          meta: String.t() | nil
        }

  @type plan_step :: %{text: String.t(), status: String.t() | nil}
  @type plan :: %{steps: [plan_step()], completed: non_neg_integer(), total: non_neg_integer()}
  @type diff_stats :: %{files: non_neg_integer(), added: non_neg_integer(), removed: non_neg_integer()}

  @type effects :: %{
          optional(:activity) => t(),
          optional(:trail) => trail_entry(),
          optional(:plan) => plan(),
          optional(:diff) => diff_stats(),
          optional(:stdout) => String.t()
        }

  @detail_limit 160
  # Agent messages are the one kind whose full text is worth reading, so they
  # keep far more than the one-line budget the other kinds are held to. The UI
  # clamps them for display and expands on demand; truncating here would make
  # the expanded view no more informative than the collapsed one.
  @message_limit 2_000
  @stdout_chunk_limit 400

  @doc """
  Maps a single codex worker update onto the state changes it implies.

  Returns an empty map for events that carry no semantics beyond liveness.
  """
  @spec observe(map()) :: effects()
  def observe(update) when is_map(update) do
    timestamp = Map.get(update, :timestamp)
    payload = payload_of(update)

    update
    |> Map.get(:event)
    |> effects_for_event(payload, timestamp)
  end

  def observe(_update), do: %{}

  @doc """
  Builds the activity a session starts out with, before any codex event lands.
  """
  @spec initial(DateTime.t() | nil) :: t()
  def initial(since) do
    %{kind: :starting, label: "Starting up", detail: nil, item_id: nil, since: since, soft: false}
  end

  @doc """
  Folds a newly observed activity into the current one.

  Two rules keep the rendered activity stable:

    * a repeat of the same activity keeps the original `since`, so the elapsed
      time reflects when the work actually started rather than the last event;
    * a *soft* activity (inferred rather than announced, e.g. "thinking" after
      an item completes) never clears a state that needs a human, which would
      otherwise make a blocked session look like it resumed on its own.
  """
  @spec advance(t() | nil, t()) :: t()
  def advance(nil, incoming), do: incoming

  def advance(current, incoming) do
    cond do
      incoming.soft and blocked?(current) -> current
      same_activity?(current, incoming) -> current
      true -> incoming
    end
  end

  defp same_activity?(current, incoming) do
    current.kind == incoming.kind and current.detail == incoming.detail and
      current.item_id == incoming.item_id
  end

  @doc """
  True when the activity means the session cannot progress without a human.
  """
  @spec blocked?(t() | nil) :: boolean()
  def blocked?(%{kind: kind}), do: kind in [:awaiting_approval, :awaiting_input]
  def blocked?(_activity), do: false

  defp effects_for_event(:session_started, _payload, timestamp) do
    %{
      activity: activity(:starting, "Starting up", nil, nil, timestamp),
      trail: trail(:starting, "Session started", nil, timestamp)
    }
  end

  defp effects_for_event(:turn_input_required, _payload, timestamp) do
    %{
      activity: activity(:awaiting_input, "Waiting for input", nil, nil, timestamp),
      trail: trail(:awaiting_input, "Turn blocked waiting for input", nil, timestamp)
    }
  end

  defp effects_for_event(:approval_required, payload, timestamp) do
    detail = command_detail(payload)

    %{
      activity: activity(:awaiting_approval, "Waiting for approval", detail, nil, timestamp),
      trail: trail(:awaiting_approval, detail || "a command", "approval required", timestamp)
    }
  end

  defp effects_for_event(:turn_completed, _payload, timestamp) do
    %{
      activity: activity(:turn_done, "Turn completed", nil, nil, timestamp),
      trail: trail(:turn_done, "Turn completed", nil, timestamp)
    }
  end

  defp effects_for_event(event, payload, timestamp) when event in [:turn_failed, :turn_ended_with_error, :startup_failed] do
    detail = error_detail(payload)

    %{
      activity: activity(:failed, "Turn failed", detail, nil, timestamp),
      trail: trail(:failed, detail || "Turn failed", "turn failed", timestamp)
    }
  end

  defp effects_for_event(:turn_cancelled, _payload, timestamp) do
    %{
      activity: activity(:failed, "Turn cancelled", nil, nil, timestamp),
      trail: trail(:failed, "Turn cancelled", nil, timestamp)
    }
  end

  defp effects_for_event(event, payload, timestamp) when event in [:tool_call_completed, :tool_call_failed] do
    tool = string_at(payload, [["params", "tool"], ["params", "name"]]) || "tool"
    verb = if event == :tool_call_completed, do: "Called", else: "Failed calling"

    %{trail: trail(:tool, tool, verb, timestamp)}
  end

  defp effects_for_event(_event, payload, timestamp) when is_map(payload) do
    case string_at(payload, [["method"]]) do
      method when is_binary(method) -> effects_for_method(method, payload, timestamp)
      _ -> %{}
    end
  end

  defp effects_for_event(_event, _payload, _timestamp), do: %{}

  defp effects_for_method("item/started", payload, timestamp) do
    item = map_at(payload, ["params", "item"]) || %{}
    item_id = string_at(item, [["id"]])

    case item_activity(item, timestamp, item_id) do
      nil -> %{}
      activity -> %{activity: activity}
    end
  end

  defp effects_for_method("item/completed", payload, timestamp) do
    item = map_at(payload, ["params", "item"]) || %{}

    case item_completion(item) do
      nil -> %{}
      {kind, title, meta} -> %{trail: trail(kind, title, meta, timestamp), activity: settled_activity(item, timestamp)}
    end
  end

  defp effects_for_method("turn/plan/updated", payload, timestamp) do
    case extract_plan(payload) do
      nil -> %{}
      plan -> %{plan: plan, trail: trail(:thinking, "Plan updated", "#{plan.completed}/#{plan.total}", timestamp)}
    end
  end

  defp effects_for_method("turn/diff/updated", payload, _timestamp) do
    case string_at(payload, [["params", "diff"]]) do
      diff when is_binary(diff) and diff != "" -> %{diff: diff_stats(diff)}
      _ -> %{}
    end
  end

  defp effects_for_method("turn/started", _payload, timestamp) do
    %{
      activity: activity(:thinking, "Thinking", nil, nil, timestamp),
      trail: trail(:thinking, "Turn started", nil, timestamp)
    }
  end

  defp effects_for_method("item/commandExecution/outputDelta", payload, _timestamp) do
    case string_at(payload, [["params", "outputDelta"], ["params", "delta"]]) do
      chunk when is_binary(chunk) and chunk != "" -> %{stdout: String.slice(chunk, 0, @stdout_chunk_limit)}
      _ -> %{}
    end
  end

  defp effects_for_method("item/commandExecution/requestApproval", payload, timestamp) do
    detail = command_detail(payload)

    %{
      activity: activity(:awaiting_approval, "Waiting for command approval", detail, nil, timestamp),
      trail: trail(:awaiting_approval, detail || "a command", "approval required", timestamp)
    }
  end

  defp effects_for_method("item/fileChange/requestApproval", payload, timestamp) do
    detail =
      case integer_at(payload, [["params", "fileChangeCount"], ["params", "changeCount"]]) do
        count when is_integer(count) and count > 0 -> "#{count} files"
        _ -> nil
      end

    %{
      activity: activity(:awaiting_approval, "Waiting for file change approval", detail, nil, timestamp),
      trail: trail(:awaiting_approval, "File changes", detail || "approval required", timestamp)
    }
  end

  defp effects_for_method(method, payload, timestamp)
       when method in ["item/tool/requestUserInput", "tool/requestUserInput"] do
    detail = string_at(payload, [["params", "question"], ["params", "prompt"]])

    %{
      activity: activity(:awaiting_input, "Waiting for input", inline(detail), nil, timestamp),
      trail: trail(:awaiting_input, inline(detail) || "Tool requires input", "input required", timestamp)
    }
  end

  defp effects_for_method("item/tool/call", payload, timestamp) do
    tool = string_at(payload, [["params", "tool"], ["params", "name"]])

    %{activity: activity(:tool, "Calling tool", tool, nil, timestamp)}
  end

  defp effects_for_method(<<"codex/event/", suffix::binary>>, payload, timestamp) do
    legacy_effects(suffix, payload, timestamp)
  end

  defp effects_for_method(_method, _payload, _timestamp), do: %{}

  # The older wrapper protocol reports command lifecycle outside item/*; keep it
  # working so deployments on either protocol get an activity rather than noise.
  defp legacy_effects("exec_command_begin", payload, timestamp) do
    detail = legacy_command_detail(payload)

    %{
      activity: activity(:command, "Running command", detail, nil, timestamp),
      trail: trail(:command, detail || "a command", nil, timestamp)
    }
  end

  defp legacy_effects("exec_command_end", payload, timestamp) do
    exit_code = integer_at(payload, [["params", "msg", "exit_code"], ["params", "msg", "exitCode"]])
    kind = if exit_code in [0, nil], do: :command, else: :failed

    meta = if is_integer(exit_code), do: "exit #{exit_code}", else: nil
    settled = Map.put(activity(:thinking, "Thinking", nil, nil, timestamp), :soft, true)

    %{activity: settled, trail: trail(kind, "Command finished", meta, timestamp)}
  end

  defp legacy_effects("exec_command_output_delta", payload, _timestamp) do
    case string_at(payload, [["params", "msg", "chunk"], ["params", "msg", "output"]]) do
      chunk when is_binary(chunk) and chunk != "" -> %{stdout: String.slice(chunk, 0, @stdout_chunk_limit)}
      _ -> %{}
    end
  end

  defp legacy_effects("turn_diff", payload, _timestamp) do
    case string_at(payload, [["params", "msg", "unified_diff"], ["params", "msg", "diff"]]) do
      diff when is_binary(diff) and diff != "" -> %{diff: diff_stats(diff)}
      _ -> %{}
    end
  end

  defp legacy_effects(_suffix, _payload, _timestamp), do: %{}

  defp item_activity(item, timestamp, item_id) do
    case string_at(item, [["type"]]) do
      "commandExecution" ->
        activity(:command, "Running command", item_command(item), item_id, timestamp)

      "fileChange" ->
        activity(:edit, "Editing files", item_files(item), item_id, timestamp)

      "reasoning" ->
        activity(:thinking, "Thinking", nil, item_id, timestamp)

      "agentMessage" ->
        activity(:writing, "Writing response", nil, item_id, timestamp)

      "mcpToolCall" ->
        activity(:tool, "Calling tool", item_tool(item), item_id, timestamp)

      "webSearch" ->
        activity(:search, "Searching the web", string_at(item, [["query"]]), item_id, timestamp)

      _ ->
        nil
    end
  end

  defp item_completion(item), do: item |> string_at([["type"]]) |> completion_for(item)

  defp completion_for("commandExecution", item), do: command_completion(item)
  defp completion_for("fileChange", item), do: {:edit, item_files(item) || "File changes", item_line_stats(item)}
  defp completion_for("agentMessage", item), do: message_completion(item)
  defp completion_for("mcpToolCall", item), do: {:tool, item_tool(item) || "a tool", nil}
  defp completion_for("webSearch", item), do: {:search, string_at(item, [["query"]]) || "a web search", nil}
  defp completion_for(_type, _item), do: nil

  # An agent message with nothing quotable is not worth a timeline entry.
  defp message_completion(item) do
    case message_text(item_text(item)) do
      nil -> nil
      text -> {:writing, text, nil}
    end
  end

  # Paragraph breaks survive because they carry the message's structure; runs of
  # spaces and blank lines do not.
  defp message_text(nil), do: nil

  defp message_text(value) when is_binary(value) do
    value
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> truncate(trimmed, @message_limit)
    end
  end

  # A completed item leaves the session generating whatever comes next; keeping
  # the finished activity on screen would misreport a long reasoning gap as a
  # still-running command.
  defp settled_activity(item, timestamp) do
    :thinking
    |> activity("Thinking", nil, string_at(item, [["id"]]), timestamp)
    |> Map.put(:soft, true)
  end

  defp command_completion(item) do
    title = item_command(item) || "a command"

    case integer_at(item, [["exitCode"], ["exit_code"]]) do
      code when is_integer(code) and code != 0 -> {:failed, title, "exit #{code}"}
      code when is_integer(code) -> {:command, title, "exit #{code}"}
      _ -> {:command, title, nil}
    end
  end

  # Line counts are reported by some app-server versions and not others; absent
  # ones stay absent rather than being rendered as zero.
  defp item_line_stats(item) do
    added = integer_at(item, [["additions"], ["added"], ["linesAdded"]])
    removed = integer_at(item, [["deletions"], ["removed"], ["linesRemoved"]])

    case {added, removed} do
      {nil, nil} -> nil
      {a, nil} -> "+#{a}"
      {nil, r} -> "−#{r}"
      {a, r} -> "+#{a} −#{r}"
    end
  end

  defp item_command(item) do
    item
    |> value_at([["command"], ["parsedCmd"], ["cmd"], ["argv"], ["args"]])
    |> normalize_command()
    |> truncate(@detail_limit)
  end

  defp item_tool(item), do: string_at(item, [["tool"], ["name"], ["server"]])

  defp item_text(item), do: string_at(item, [["text"], ["message"], ["content"]])

  defp item_files(item) do
    case value_at(item, [["changes"], ["files"], ["paths"]]) do
      changes when is_list(changes) and changes != [] ->
        changes
        |> Enum.map(&change_path/1)
        |> Enum.reject(&is_nil/1)
        |> summarize_paths()

      _ ->
        case integer_at(item, [["fileChangeCount"], ["changeCount"]]) do
          count when is_integer(count) and count > 0 -> "#{count} files"
          _ -> nil
        end
    end
  end

  defp change_path(change) when is_map(change), do: string_at(change, [["path"], ["file"], ["uri"]])
  defp change_path(change) when is_binary(change), do: change
  defp change_path(_change), do: nil

  defp summarize_paths([]), do: nil
  defp summarize_paths([path]), do: truncate(Path.basename(path), @detail_limit)

  defp summarize_paths([path | rest]) do
    truncate("#{Path.basename(path)} +#{length(rest)} more", @detail_limit)
  end

  defp command_detail(payload) do
    payload
    |> value_at([["params", "parsedCmd"], ["params", "command"], ["params", "cmd"], ["params", "argv"], ["params", "args"]])
    |> normalize_command()
    |> truncate(@detail_limit)
  end

  defp legacy_command_detail(payload) do
    payload
    |> value_at([["params", "msg", "command"], ["params", "msg", "parsed_cmd"]])
    |> normalize_command()
    |> truncate(@detail_limit)
  end

  defp normalize_command(command) when is_binary(command), do: command

  defp normalize_command(command) when is_list(command) do
    command
    |> Enum.map(&normalize_command/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " ")
    end
  end

  defp normalize_command(command) when is_map(command) do
    base = string_at(command, [["parsedCmd"], ["command"], ["cmd"]])
    args = value_at(command, [["args"], ["argv"]])

    cond do
      is_binary(base) and is_list(args) -> normalize_command([base | args])
      is_binary(base) -> base
      true -> nil
    end
  end

  defp normalize_command(_command), do: nil

  defp error_detail(payload) do
    payload
    |> string_at([["params", "error", "message"], ["error", "message"], ["reason"], ["message"]])
    |> inline()
  end

  defp extract_plan(payload) do
    entries = value_at(payload, [["params", "plan"], ["params", "steps"], ["params", "items"]])

    if is_list(entries) do
      steps = Enum.map(entries, &plan_step/1)
      %{steps: steps, completed: Enum.count(steps, &(&1.status == "completed")), total: length(steps)}
    end
  end

  defp plan_step(entry) when is_map(entry) do
    text = string_at(entry, [["step"], ["text"], ["title"], ["description"]]) || ""
    %{text: truncate(text, @detail_limit), status: string_at(entry, [["status"]])}
  end

  defp plan_step(entry) when is_binary(entry), do: %{text: truncate(entry, @detail_limit), status: nil}
  defp plan_step(_entry), do: %{text: "", status: nil}

  # Unified diff accounting: `+++`/`---` are file headers, not changed lines.
  defp diff_stats(diff) do
    diff
    |> String.split("\n")
    |> Enum.reduce(%{files: 0, added: 0, removed: 0}, fn
      "+++" <> _rest, acc -> %{acc | files: acc.files + 1}
      "---" <> _rest, acc -> acc
      "+" <> _rest, acc -> %{acc | added: acc.added + 1}
      "-" <> _rest, acc -> %{acc | removed: acc.removed + 1}
      _line, acc -> acc
    end)
  end

  defp activity(kind, label, detail, item_id, timestamp) do
    %{kind: kind, label: label, detail: detail, item_id: item_id, since: timestamp, soft: false}
  end

  defp trail(kind, title, meta, timestamp), do: %{at: timestamp, kind: kind, title: title, meta: meta}

  defp inline(nil), do: nil

  defp inline(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> truncate(trimmed, @detail_limit)
    end
  end

  defp truncate(nil, _limit), do: nil

  defp truncate(value, limit) when is_binary(value) do
    if String.length(value) > limit do
      String.slice(value, 0, limit - 1) <> "…"
    else
      value
    end
  end

  defp payload_of(update) do
    case Map.get(update, :payload) do
      %{} = payload -> payload
      _ -> Map.get(update, :raw)
    end
  end

  defp map_at(source, path) do
    case value_at(source, [path]) do
      %{} = value -> value
      _ -> nil
    end
  end

  defp string_at(source, paths) do
    case value_at(source, paths) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp integer_at(source, paths) do
    case value_at(source, paths) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  # Every caller reaches here with a map, either by guard or by defaulting to
  # `%{}`, so a non-map source is a bug rather than a payload shape to absorb.
  defp value_at(source, paths) when is_map(source) and is_list(paths) do
    Enum.find_value(paths, fn path -> dig(source, path) end)
  end

  defp dig(%{} = source, [key]), do: Map.get(source, key) || Map.get(source, safe_atom(key))

  defp dig(%{} = source, [key | rest]) do
    case Map.get(source, key) || Map.get(source, safe_atom(key)) do
      %{} = nested -> dig(nested, rest)
      _ -> nil
    end
  end

  # Payloads arrive as decoded JSON with string keys; test and internal callers
  # sometimes use atoms. Never create atoms from untrusted payload keys.
  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
