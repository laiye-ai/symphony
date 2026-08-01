defmodule SymphonyElixir.OrchestratorActivityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.Activity

  defp start_orchestrator(name) do
    orchestrator_name = Module.concat(__MODULE__, name)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    pid
  end

  defp inject_running(pid, issue_id, started_at, overrides \\ %{}) do
    issue = %Issue{
      id: issue_id,
      identifier: "MT-ACT",
      title: "Activity test",
      state: "In Progress",
      url: "https://example.org/issues/MT-ACT"
    }

    entry =
      Map.merge(
        %{
          pid: self(),
          ref: make_ref(),
          identifier: issue.identifier,
          issue: issue,
          worker_host: nil,
          workspace_path: nil,
          session_id: "thread-act",
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          codex_app_server_pid: nil,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          codex_last_reported_input_tokens: 0,
          codex_last_reported_output_tokens: 0,
          codex_last_reported_total_tokens: 0,
          turn_count: 0,
          retry_attempt: nil,
          started_at: started_at,
          activity: Activity.initial(started_at),
          last_progress_at: started_at,
          activity_trail: [],
          plan: nil,
          diff_stats: nil,
          stdout_tail: ""
        },
        overrides
      )

    :sys.replace_state(pid, fn state ->
      state
      |> Map.put(:running, %{issue_id => entry})
      |> Map.put(:claimed, MapSet.put(state.claimed, issue_id))
    end)

    entry
  end

  defp notification(method, params, timestamp) do
    %{event: :notification, timestamp: timestamp, payload: %{"method" => method, "params" => params}}
  end

  defp running_entry(pid) do
    %{running: [entry]} = GenServer.call(pid, :snapshot)
    entry
  end

  test "streaming noise refreshes the heartbeat without changing the reported activity" do
    pid = start_orchestrator(:Heartbeat)
    started_at = ~U[2026-07-31 08:00:00Z]
    inject_running(pid, "issue-heartbeat", started_at)

    send(
      pid,
      {:codex_worker_update, "issue-heartbeat",
       notification(
         "item/started",
         %{"item" => %{"id" => "exec-1", "type" => "commandExecution", "command" => "mix test"}},
         ~U[2026-07-31 08:01:00Z]
       )}
    )

    send(
      pid,
      {:codex_worker_update, "issue-heartbeat", notification("item/reasoning/textDelta", %{"delta" => "still thinking"}, ~U[2026-07-31 08:03:30Z])}
    )

    entry = running_entry(pid)

    assert entry.activity.kind == :command
    assert entry.activity.detail == "mix test"
    # The activity still dates from when the command started...
    assert entry.activity.since == ~U[2026-07-31 08:01:00Z]
    # ...while the delta, which carries no meaning of its own, proves liveness.
    assert entry.last_progress_at == ~U[2026-07-31 08:03:30Z]
  end

  test "the trail records semantic events only and stays bounded" do
    pid = start_orchestrator(:Trail)
    started_at = ~U[2026-07-31 08:00:00Z]
    inject_running(pid, "issue-trail", started_at)

    Enum.each(1..60, fn index ->
      send(
        pid,
        {:codex_worker_update, "issue-trail",
         notification(
           "item/completed",
           %{"item" => %{"id" => "exec-#{index}", "type" => "commandExecution", "command" => "step #{index}"}},
           started_at
         )}
      )

      send(
        pid,
        {:codex_worker_update, "issue-trail", notification("item/reasoning/textDelta", %{"delta" => "noise #{index}"}, started_at)}
      )
    end)

    entry = running_entry(pid)

    assert length(entry.activity_trail) == 50
    assert Enum.all?(entry.activity_trail, &(&1.title =~ ~r/^step \d+$/))
    assert List.first(entry.activity_trail).title == "step 60"
  end

  test "captured command output is bounded and stays valid utf-8" do
    pid = start_orchestrator(:Stdout)
    started_at = ~U[2026-07-31 08:00:00Z]
    inject_running(pid, "issue-stdout", started_at)

    chunk = String.duplicate("中", 400)

    Enum.each(1..3, fn _index ->
      send(
        pid,
        {:codex_worker_update, "issue-stdout", notification("item/commandExecution/outputDelta", %{"outputDelta" => chunk}, started_at)}
      )
    end)

    entry = running_entry(pid)

    assert byte_size(entry.stdout_tail) <= 2_048
    assert String.valid?(entry.stdout_tail)
    assert String.ends_with?(entry.stdout_tail, "中")
  end

  test "issues with no session are retained with the state they are parked in" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    parked = %Issue{
      id: "issue-parked",
      identifier: "MT-PARKED",
      title: "Waiting on CI",
      # Not an active state, so the orchestrator will never dispatch it -- the
      # exact case that used to be invisible on the dashboard.
      state: "Agent Review",
      labels: ["gate:ci"],
      url: "https://example.org/issues/MT-PARKED"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [parked])
    on_exit(fn -> Application.put_env(:symphony_elixir, :memory_tracker_issues, []) end)

    pid = start_orchestrator(:Observed)

    send(pid, :run_poll_cycle)
    %{observed: [first]} = GenServer.call(pid, :snapshot)

    assert first.identifier == "MT-PARKED"
    assert first.state == "Agent Review"
    assert first.labels == ["gate:ci"]
    # First sighting: the orchestrator never saw the transition, so the dwell
    # time is only a lower bound and must say so.
    refute first.state_since_exact?

    send(pid, :run_poll_cycle)
    %{observed: [second]} = GenServer.call(pid, :snapshot)

    assert second.state_since == first.state_since
    refute second.state_since_exact?

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{parked | state: "Merging"}])
    send(pid, :run_poll_cycle)
    %{observed: [moved]} = GenServer.call(pid, :snapshot)

    assert moved.state == "Merging"
    assert moved.state_since_exact?
  end

  test "an issue never appears as both running and awaiting dispatch" do
    pid = start_orchestrator(:NoDoubleCount)
    started_at = DateTime.utc_now()
    inject_running(pid, "issue-both", started_at)

    # Dispatch happens later in the same poll cycle that records observed
    # issues, so the two views overlap for a moment unless the snapshot filters.
    :sys.replace_state(pid, fn state ->
      Map.put(state, :observed, %{
        "issue-both" => %{
          issue_id: "issue-both",
          identifier: "MT-ACT",
          title: "Both",
          state: "In Progress",
          url: nil,
          labels: [],
          state_since: started_at,
          state_since_exact?: true,
          active_state?: true,
          last_seen_at: started_at
        }
      })
    end)

    %{running: [running], observed: observed} = GenServer.call(pid, :snapshot)

    assert running.identifier == "MT-ACT"
    assert observed == []
  end

  test "issues routed to another worker are never observed at all" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    mine = %Issue{
      id: "issue-mine",
      identifier: "MT-MINE",
      title: "Mine",
      state: "Agent Review",
      url: "https://example.org/issues/MT-MINE"
    }

    theirs = %Issue{
      id: "issue-theirs",
      identifier: "MT-THEIRS",
      title: "Someone else's",
      state: "Agent Review",
      assigned_to_worker: false,
      url: "https://example.org/issues/MT-THEIRS"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [mine, theirs])
    on_exit(fn -> Application.put_env(:symphony_elixir, :memory_tracker_issues, []) end)

    pid = start_orchestrator(:Routing)
    send(pid, :run_poll_cycle)

    %{observed: observed} = GenServer.call(pid, :snapshot)

    assert Enum.map(observed, & &1.identifier) == ["MT-MINE"]
  end

  test "a finished session stays available after it leaves the running set" do
    pid = start_orchestrator(:Recent)
    started_at = DateTime.add(DateTime.utc_now(), -30, :second)
    entry = inject_running(pid, "issue-recent", started_at, %{codex_total_tokens: 4_242, turn_count: 3})

    send(
      pid,
      {:codex_worker_update, "issue-recent",
       notification(
         "item/completed",
         %{"item" => %{"id" => "exec-1", "type" => "commandExecution", "command" => "git push"}},
         DateTime.utc_now()
       )}
    )

    _flush = GenServer.call(pid, :snapshot)
    send(pid, {:DOWN, entry.ref, :process, self(), :normal})

    %{running: running, recent: [recent]} = GenServer.call(pid, :snapshot)

    assert running == []
    assert recent.issue_id == "issue-recent"
    assert recent.outcome == :completed
    assert recent.turn_count == 3
    assert recent.tokens.total_tokens == 4_242
    assert recent.runtime_seconds >= 30
    assert Enum.any?(recent.activity_trail, &(&1.title == "git push"))
  end
end
