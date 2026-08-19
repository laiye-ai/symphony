defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, PromptArchive, StatusDashboard}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    with_snapshot(orchestrator, snapshot_timeout_ms, &list_payload/2)
  end

  @doc """
  Builds the dashboard payload: every issue in list form, plus the full detail
  for the selected one.

  The list projection is deliberately light and the detail projection is not, so
  both are derived from a single snapshot rather than costing the orchestrator a
  second `GenServer.call` on every one-second refresh.
  """
  @spec dashboard_payload(GenServer.name(), timeout(), String.t() | nil) :: map()
  def dashboard_payload(orchestrator, snapshot_timeout_ms, selected_identifier) do
    with_snapshot(orchestrator, snapshot_timeout_ms, fn snapshot, generated_at ->
      snapshot
      |> list_payload(generated_at)
      |> Map.put(:detail, selected_detail(snapshot, selected_identifier))
    end)
  end

  defp with_snapshot(orchestrator, snapshot_timeout_ms, builder) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        builder.(snapshot, generated_at)

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  defp list_payload(snapshot, generated_at) do
    observed = Map.get(snapshot, :observed, [])

    %{
      generated_at: generated_at,
      counts: %{
        running: length(snapshot.running),
        retrying: length(snapshot.retrying),
        observed: length(observed)
      },
      running: Enum.map(snapshot.running, &running_entry_payload/1),
      retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
      observed: Enum.map(observed, &observed_entry_payload/1),
      recent: snapshot |> Map.get(:recent, []) |> Enum.map(&recent_entry_payload/1),
      active_states: Map.get(snapshot, :active_states, []),
      parked_states: Map.get(snapshot, :parked_states, []),
      codex_totals: snapshot.codex_totals,
      rate_limits: snapshot.rate_limits
    }
  end

  defp selected_detail(_snapshot, nil), do: nil

  defp selected_detail(snapshot, identifier) do
    case find_issue_entries(snapshot, identifier) do
      nil -> nil
      found -> issue_payload_body(identifier, found)
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        case find_issue_entries(snapshot, issue_identifier) do
          nil -> {:error, :issue_not_found}
          found -> {:ok, issue_payload_body(issue_identifier, found)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  defp find_issue_entries(snapshot, issue_identifier) do
    found = %{
      running: Enum.find(snapshot.running, &(&1.identifier == issue_identifier)),
      retry: Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier)),
      recent: snapshot |> Map.get(:recent, []) |> Enum.find(&(&1.identifier == issue_identifier)),
      observed: snapshot |> Map.get(:observed, []) |> Enum.find(&(&1.identifier == issue_identifier))
    }

    if Enum.all?(Map.values(found), &is_nil/1), do: nil, else: found
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, %{running: running, retry: retry} = found) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(found),
      status: issue_status(found),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      recent: found.recent && recent_entry_payload(found.recent),
      observed: found.observed && observed_entry_payload(found.observed),
      logs: %{
        codex_session_logs: []
      },
      # From the archive directory, not from orchestrator state: the index
      # outlives both trail eviction and restarts, and every status gets it --
      # a finished or parked issue still has readable prompt history.
      prompts: prompts_payload(issue_identifier),
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(found) do
    [:running, :retry, :recent, :observed]
    |> Enum.map(&Map.get(found, &1))
    |> Enum.find_value(&(&1 && Map.get(&1, :issue_id)))
  end

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  # A live session outranks every other view of the same issue; an issue that is
  # only observed has no session at all and must not read as if it were working.
  defp issue_status(%{running: running}) when not is_nil(running), do: "running"
  defp issue_status(%{retry: retry}) when not is_nil(retry), do: "retrying"
  # The tracker's state outranks a finished session: the session is over, the
  # issue is not. An issue that self-parked is the case that matters -- calling
  # it "finished" hides the one queue that is waiting on a person. This matches
  # the rail, which already lists such an issue under its parked state rather
  # than under recently finished.
  defp issue_status(%{observed: observed}) when not is_nil(observed), do: "observed"
  defp issue_status(%{recent: recent}) when not is_nil(recent), do: "finished"
  defp issue_status(_found), do: "observed"

  # The list projection stays deliberately light: the per-issue endpoint carries
  # the event trail and command output, so a session list of any size costs the
  # same to push on every refresh.
  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      activity: activity_payload(Map.get(entry, :activity)),
      last_progress_at: iso8601(Map.get(entry, :last_progress_at)),
      plan: plan_summary(Map.get(entry, :plan)),
      diff_stats: Map.get(entry, :diff_stats),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp observed_entry_payload(entry) do
    %{
      issue_id: Map.get(entry, :issue_id),
      issue_identifier: Map.get(entry, :identifier),
      title: Map.get(entry, :title),
      state: Map.get(entry, :state),
      url: Map.get(entry, :url),
      labels: Map.get(entry, :labels, []),
      state_since: iso8601(Map.get(entry, :state_since)),
      # False means the orchestrator never witnessed the transition into this
      # state, so `state_seconds` is a lower bound and must render as such.
      state_since_exact: Map.get(entry, :state_since_exact?, false),
      state_seconds: Map.get(entry, :state_seconds, 0),
      active_state: Map.get(entry, :active_state?, false),
      last_seen_at: iso8601(Map.get(entry, :last_seen_at))
    }
  end

  defp recent_entry_payload(entry) do
    %{
      issue_id: Map.get(entry, :issue_id),
      issue_identifier: Map.get(entry, :identifier),
      title: Map.get(entry, :title),
      outcome: Map.get(entry, :outcome),
      reason: Map.get(entry, :reason),
      worker_host: Map.get(entry, :worker_host),
      session_id: Map.get(entry, :session_id),
      turn_count: Map.get(entry, :turn_count, 0),
      started_at: iso8601(Map.get(entry, :started_at)),
      finished_at: iso8601(Map.get(entry, :finished_at)),
      runtime_seconds: Map.get(entry, :runtime_seconds, 0),
      tokens: Map.get(entry, :tokens),
      diff_stats: Map.get(entry, :diff_stats),
      plan: plan_summary(Map.get(entry, :plan)),
      activity_trail: trail_payload(Map.get(entry, :activity_trail, []))
    }
  end

  defp activity_payload(%{} = activity) do
    %{
      kind: Map.get(activity, :kind),
      label: Map.get(activity, :label),
      detail: Map.get(activity, :detail),
      since: iso8601(Map.get(activity, :since))
    }
  end

  defp activity_payload(_activity), do: nil

  defp plan_summary(%{steps: steps} = plan) when is_list(steps) do
    %{
      completed: Map.get(plan, :completed, 0),
      total: Map.get(plan, :total, length(steps)),
      current: current_plan_step(steps)
    }
  end

  defp plan_summary(_plan), do: nil

  defp current_plan_step(steps) do
    case Enum.find(steps, &(&1.status == "in_progress")) do
      %{text: text} -> text
      _ -> steps |> Enum.find(&(&1.status != "completed")) |> plan_step_text()
    end
  end

  defp plan_step_text(%{text: text}), do: text
  defp plan_step_text(_step), do: nil

  defp trail_payload(trail) when is_list(trail) do
    Enum.map(trail, fn entry ->
      %{
        at: iso8601(Map.get(entry, :at)),
        kind: Map.get(entry, :kind),
        title: Map.get(entry, :title),
        meta: Map.get(entry, :meta),
        prompt: prompt_payload(Map.get(entry, :prompt))
      }
    end)
  end

  defp trail_payload(_trail), do: []

  defp prompt_payload(%{identifier: identifier, basename: basename} = prompt)
       when is_binary(identifier) and is_binary(basename) do
    %{
      identifier: identifier,
      basename: basename,
      turn: Map.get(prompt, :turn),
      chars: Map.get(prompt, :chars)
    }
  end

  defp prompt_payload(_prompt), do: nil

  defp prompts_payload(issue_identifier) do
    issue_identifier
    |> PromptArchive.list()
    |> Enum.map(fn entry ->
      %{
        identifier: entry.identifier,
        basename: entry.basename,
        turn: entry.turn,
        at: iso8601(entry.at)
      }
    end)
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp running_issue_payload(running) do
    %{
      title: Map.get(running, :title),
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      activity: activity_payload(Map.get(running, :activity)),
      last_progress_at: iso8601(Map.get(running, :last_progress_at)),
      activity_trail: trail_payload(Map.get(running, :activity_trail, [])),
      plan: Map.get(running, :plan),
      diff_stats: Map.get(running, :diff_stats),
      stdout_tail: Map.get(running, :stdout_tail, ""),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
