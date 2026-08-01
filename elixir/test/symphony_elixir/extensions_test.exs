defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1, "observed" => 0},
             "active_states" => ["Todo", "In Progress", "Agent Review"],
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "title" => nil,
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "activity" => nil,
                 "last_progress_at" => nil,
                 "plan" => nil,
                 "diff_stats" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "observed" => [],
             "recent" => [],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "title" => nil,
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "activity" => nil,
               "last_progress_at" => nil,
               "activity_trail" => [],
               "plan" => nil,
               "diff_stats" => nil,
               "stdout_tail" => "",
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "recent" => nil,
             "observed" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    # The served stylesheet is Tailwind's minified build output, so it is checked
    # for having actually been produced and for carrying the app's own rules.
    # The design invariants below are asserted against the source, which is what
    # a future edit would break.
    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ "tailwindcss v4"
    assert dashboard_css =~ ".rail-row-selected"
    assert dashboard_css =~ "prefers-color-scheme:dark"
    assert dashboard_css =~ "[data-phx-main].phx-connected .conn-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .conn-offline"
    assert dashboard_css =~ ".trail-row:not(.trail-open).trail-thinking .trail-head"
    assert dashboard_css =~ ".trail-card.is-clamped .trail-toggle"

    source_css = File.read!(Path.join(:code.priv_dir(:symphony_elixir), "../assets/css/app.css"))
    # The shell must be bounded, not merely tall: with min-height the page grows
    # to fit the timeline and the inner overflow never engages.
    assert source_css =~ ~r/\.shell \{[^}]*h-screen[^}]*overflow-hidden/s
    refute source_css =~ ~r/\.shell \{[^}]*min-h-screen/s
    # Text never sits on the saturated accent: white on it is 3.2:1, under the
    # 4.5:1 floor. The selected row therefore fills with the container tint.
    assert source_css =~ ~r/\.rail-row-selected,[^}]*background: var\(--color-primary-container\);/s
    assert source_css =~ ~r/@media \(prefers-color-scheme: dark\)[^}]*--color-on-primary-container:/s
    # The live row shares its kind with turn boundaries, so every rule that
    # hides boundary chrome must exclude it -- otherwise the current activity,
    # the one line the page exists to show, renders blank while thinking.
    refute source_css =~ "\n  .trail-thinking .trail-head"
    # The expand affordance stays hidden until the browser reports a clip, and
    # never draws a focus ring around the icon.
    assert source_css =~ ~r/\.trail-toggle \{[^}]*hidden/s
    assert source_css =~ ~r/\.trail-toggle \{[^}]*outline: none;/s

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview reports the current activity and heartbeat instead of the last raw event" do
    orchestrator_name = Module.concat(__MODULE__, :ActivityDashboardOrchestrator)
    now = DateTime.utc_now()

    snapshot =
      put_in(static_snapshot().running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          title: "Desktop: move the privacy review into the session stream",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 2,
          last_codex_event: :notification,
          # The last raw event is exactly the sort of noise the old column showed.
          last_codex_message: %{
            event: :notification,
            message: %{"method" => "item/reasoning/textDelta", "params" => %{"delta" => "…"}}
          },
          last_codex_timestamp: now,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.add(now, -300, :second),
          activity: %{
            kind: :command,
            label: "Running command",
            detail: "pnpm vitest run src/interaction",
            item_id: "exec-1",
            since: DateTime.add(now, -41, :second),
            soft: false
          },
          last_progress_at: DateTime.add(now, -600, :second),
          plan: %{steps: [], completed: 4, total: 7},
          diff_stats: %{files: 6, added: 148, removed: 32}
        }
      ])

    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Running command"
    assert html =~ ~s(<p class="detail-title">Desktop: move the privacy review into the session stream</p>)
    assert html =~ ~s(<span class="chip chip-danger">running</span>)
    assert html =~ "pnpm vitest run src/interaction"
    assert html =~ "4/7"
    assert html =~ "+148"
    assert html =~ "−32"
    assert html =~ "in 6 files"
    # Ten minutes without an event is a stalled session: it must sort into the
    # attention lane and read as stalled rather than as busy.
    assert html =~ "Needs attention · 1"
    assert html =~ "dot dot-danger"
    assert html =~ ~s(class="tone-danger")
    # Loose on the seconds: the clock advances between building the snapshot and
    # rendering it, and the point of the assertion is the ten-minute gap.
    assert html =~ ~r{10m \d+s ago</b>\s*since last event}
    refute html =~ "item/reasoning/textDelta"
  end

  test "dashboard drops stale command output and ranks stream events by kind" do
    orchestrator_name = Module.concat(__MODULE__, :StreamOrchestrator)
    now = DateTime.utc_now()

    snapshot =
      put_in(static_snapshot().running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 1,
          last_codex_event: :notification,
          last_codex_message: nil,
          last_codex_timestamp: now,
          codex_input_tokens: 1,
          codex_output_tokens: 1,
          codex_total_tokens: 2,
          started_at: now,
          last_progress_at: now,
          # Reasoning, not a command -- so the buffered output below belongs to
          # something that already finished.
          activity: %{kind: :thinking, label: "Thinking", detail: nil, item_id: nil, since: now, soft: false},
          stdout_tail: "[symphony-owner-gate] ALLOW Issue MT-HTTP",
          activity_trail: [
            %{at: now, kind: :failed, title: "node review-preflight.mjs", meta: "exit 2"},
            %{at: now, kind: :writing, title: "I will run the owner gate first, then read the review policy.", meta: nil},
            %{at: now, kind: :command, title: "git status --short", meta: "exit 0"},
            %{at: now, kind: :starting, title: "Session started", meta: nil}
          ]
        }
      ])

    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    refute html =~ "symphony-owner-gate"
    assert html =~ ~s(class="trail-row trail-failed")
    assert html =~ ~s(class="trail-row trail-writing")
    assert html =~ ~s(class="trail-row trail-command")
    assert html =~ ~s(class="trail-row trail-starting")

    # The current activity is the head of the same timeline, still open.
    assert html =~ ~s(class="trail-row trail-open trail-thinking")
    assert html =~ "in progress"

    # Structured facts render as their own field, not glued into the title.
    assert html =~ ~s(<span class="trail-kind">failed</span>)
    assert html =~ ~s(<span class="trail-kind">agent message</span>)
    assert html =~ "exit 2"
    assert html =~ "node review-preflight.mjs"
  end

  test "agent messages toggle between clamped and full text" do
    orchestrator_name = Module.concat(__MODULE__, :ExpandOrchestrator)
    now = DateTime.utc_now()
    long_message = String.duplicate("已定位到一个真实竞态，", 20) <> "\n\n继续核对其余 AC。"

    snapshot =
      put_in(static_snapshot().running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 1,
          last_codex_event: :notification,
          last_codex_message: nil,
          last_codex_timestamp: now,
          codex_input_tokens: 1,
          codex_output_tokens: 1,
          codex_total_tokens: 2,
          started_at: now,
          last_progress_at: now,
          activity: %{kind: :thinking, label: "Thinking", detail: nil, item_id: nil, since: now, soft: false},
          stdout_tail: "",
          activity_trail: [
            %{at: now, kind: :writing, title: long_message, meta: nil},
            %{at: now, kind: :command, title: "git status", meta: "exit 0"}
          ]
        }
      ])

    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")

    # Whether the text is clipped is measured in the browser, so the control
    # ships for every message and CSS reveals it; only messages get one.
    assert html =~ ~s(phx-hook="Clamp")
    # The control is an icon, not a word, and reports its state to assistive tech.
    assert html =~ ~s(aria-expanded="false")
    assert html =~ "<svg"
    assert length(String.split(html, ~s(class="trail-toggle"))) == 2
    refute html =~ "trail-body-expanded"
    refute html =~ "is-expanded"

    html = view |> element("button.trail-toggle") |> render_click()

    assert html =~ "trail-body-expanded"
    assert html =~ "is-expanded"
    assert html =~ "继续核对其余 AC。"

    html = view |> element("button.trail-toggle") |> render_click()

    refute html =~ "trail-body-expanded"
    refute html =~ "is-expanded"
  end

  test "live sessions are grouped by tracker stage in the configured order" do
    orchestrator_name = Module.concat(__MODULE__, :StageOrchestrator)
    now = DateTime.utc_now()

    session = fn identifier, state ->
      %{
        issue_id: "issue-#{identifier}",
        identifier: identifier,
        state: state,
        session_id: "thread-#{identifier}",
        turn_count: 1,
        last_codex_event: :notification,
        last_codex_message: nil,
        last_codex_timestamp: now,
        codex_input_tokens: 1,
        codex_output_tokens: 1,
        codex_total_tokens: 2,
        started_at: now,
        last_progress_at: now,
        activity: %{kind: :thinking, label: "Thinking", detail: nil, item_id: nil, since: now, soft: false},
        stdout_tail: "",
        activity_trail: []
      }
    end

    snapshot =
      static_snapshot()
      |> Map.put(:active_states, ["Todo", "In Progress", "Rework", "Agent Review"])
      |> Map.put(:running, [
        session.("MT-REVIEW", "Agent Review"),
        session.("MT-PROG", "In Progress"),
        session.("MT-REWORK", "Rework"),
        session.("MT-ODD", "Some Custom State")
      ])

    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    lanes = Regex.scan(~r/lane-label lane-label-([a-z0-9-]+)">([^<]+)/, html) |> Enum.map(&Enum.at(&1, 2))

    # Pipeline order comes from the workflow config, not from this module, and
    # a stage with nobody in it does not take up a lane.
    assert ["In Progress · 1", "Rework · 1", "Agent Review · 1" | rest] = Enum.map(lanes, &String.trim/1)
    refute Enum.any?(lanes, &String.contains?(&1, "Todo"))
    # A state the config never listed still gets a home rather than vanishing.
    assert Enum.any?(rest, &String.contains?(&1, "Some Custom State"))
    assert html =~ "lane-label-stage-agent-review"
  end

  test "runs of plumbing collapse into one row and expand on demand" do
    orchestrator_name = Module.concat(__MODULE__, :GroupingOrchestrator)
    now = DateTime.utc_now()

    trail =
      [
        %{at: now, kind: :writing, title: "Preflight is green, starting the review.", meta: nil},
        %{at: now, kind: :command, title: "gh pr view 218", meta: "exit 0"},
        %{at: now, kind: :tool, title: "linear_graphql", meta: "Called"},
        %{at: now, kind: :command, title: "git status --short", meta: "exit 0"},
        %{at: now, kind: :command, title: "rg privacy src/", meta: "exit 0"},
        # A failure breaks the run: it is the thing you came to find.
        %{at: now, kind: :failed, title: "mix dialyzer", meta: "exit 2"},
        %{at: now, kind: :command, title: "git log --oneline", meta: "exit 0"},
        %{at: now, kind: :command, title: "git diff --stat", meta: "exit 0"}
      ]

    snapshot =
      put_in(static_snapshot().running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 1,
          last_codex_event: :notification,
          last_codex_message: nil,
          last_codex_timestamp: now,
          codex_input_tokens: 1,
          codex_output_tokens: 1,
          codex_total_tokens: 2,
          started_at: now,
          last_progress_at: now,
          activity: %{kind: :thinking, label: "Thinking", detail: nil, item_id: nil, since: now, soft: false},
          stdout_tail: "",
          activity_trail: trail
        }
      ])

    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")

    # The run of four before the failure collapses; the pair after it is too
    # short to be worth a click and stays inline.
    assert html =~ "4 steps"
    refute html =~ "2 steps"
    assert html =~ "git log --oneline"
    # Collapsed steps are not in the document until asked for.
    refute html =~ "rg privacy src/"
    # What matters stays first class.
    assert html =~ "Preflight is green"
    assert html =~ "mix dialyzer"

    html = view |> element("button.trail-group-head") |> render_click()

    assert html =~ "rg privacy src/"
    assert html =~ "linear_graphql"
  end

  test "an issue with both a live session and a finished one is listed once" do
    orchestrator_name = Module.concat(__MODULE__, :RelistedOrchestrator)
    now = DateTime.utc_now()

    # A completed session does not prevent re-dispatch, so the orchestrator
    # genuinely holds both records for CLA-RETRY at the same time.
    snapshot =
      Map.put(static_snapshot(), :recent, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          title: "Relisted",
          outcome: :completed,
          reason: nil,
          worker_host: nil,
          session_id: "thread-old",
          turn_count: 1,
          started_at: DateTime.add(now, -600, :second),
          finished_at: DateTime.add(now, -300, :second),
          runtime_seconds: 300,
          tokens: %{input_tokens: 1, output_tokens: 1, total_tokens: 2},
          diff_stats: nil,
          plan: nil,
          activity_trail: [%{at: now, kind: :turn_done, title: "Turn completed", meta: nil}]
        }
      ])

    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/?issue=MT-HTTP")

    # It is working, so it belongs to the working lane and nowhere else.
    assert html =~ "In Progress · 1"
    refute html =~ "Recently finished"
    # The finished session is still reachable, in the pane where history lives.
    assert html =~ "Last session"
  end

  test "parked issues report a lower-bound dwell time when the transition was not witnessed" do
    orchestrator_name = Module.concat(__MODULE__, :ObservedOrchestrator)

    snapshot =
      Map.put(static_snapshot(), :observed, [
        %{
          issue_id: "issue-parked",
          identifier: "MT-PARKED",
          title: "Waiting on CI",
          state: "Agent Review",
          url: nil,
          labels: ["gate:ci"],
          state_since: DateTime.utc_now(),
          state_since_exact?: false,
          state_seconds: 900,
          active_state?: false,
          last_seen_at: DateTime.utc_now()
        }
      ])

    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/?issue=MT-PARKED")

    assert html =~ "Handed off · 1"
    assert html =~ "no session will start"
    assert html =~ "gate:ci"
    # The orchestrator never saw the transition, so the duration is a bound.
    assert html =~ "≥15m 0s"
  end

  test "dashboard selection is driven by the query string and survives a reload" do
    orchestrator_name = Module.concat(__MODULE__, :SelectionOrchestrator)

    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    # A deep link opens straight onto the issue it names, so a stalled session
    # can be handed to someone else as a URL.
    {:ok, view, html} = live(build_conn(), "/?issue=MT-RETRY")
    assert html =~ ~s(<span class="detail-id">MT-RETRY</span>)
    assert html =~ "Waiting to retry · attempt 2"

    html = view |> element(~s(button[phx-value-issue="MT-HTTP"])) |> render_click()
    assert html =~ ~s(<span class="detail-id">MT-HTTP</span>)
    assert_patched(view, "/?issue=MT-HTTP")
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Symphony"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "rendered"
    assert html =~ "In Progress · 1"
    assert html =~ "Retrying · 1"
    # The first issue is selected automatically so the pane is never blank.
    assert html =~ ~s(class="rail-row rail-row-selected")
    assert html =~ ~s(<a href="/api/v1/MT-HTTP">)
    # Both connection states ship; CSS picks between them off the socket class.
    assert html =~ "conn-live"
    assert html =~ "conn-offline"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1, "observed" => 0}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ "tailwindcss v4"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      active_states: ["Todo", "In Progress", "Agent Review"],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
