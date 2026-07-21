defmodule SymphonyElixir.LinearRateLimitTest.LinearClientStub do
  @moduledoc """
  Injectable Linear client stub driven by :persistent_term so orchestrator
  retry flows can simulate RATELIMITED responses deterministically.
  """

  alias SymphonyElixir.Linear.Issue

  @mode_key {__MODULE__, :mode}
  @recipient_key {__MODULE__, :recipient}

  def set_mode(mode), do: :persistent_term.put(@mode_key, mode)
  def set_recipient(pid), do: :persistent_term.put(@recipient_key, pid)

  def clear do
    :persistent_term.erase(@mode_key)
    :persistent_term.erase(@recipient_key)
    :ok
  end

  def issue do
    %Issue{
      id: "issue-rate-limited",
      identifier: "MT-900",
      title: "Rate limited issue",
      description: "Issue used for rate-limit retry tests",
      state: "In Progress",
      labels: [],
      blocked_by: [],
      assigned_to_worker: true
    }
  end

  def fetch_candidate_issues do
    notify(:fetch_candidate_issues)
    {:ok, [issue()]}
  end

  def fetch_issues_by_states(_state_names) do
    notify(:fetch_issues_by_states)
    {:ok, []}
  end

  def fetch_issue_states_by_ids(_issue_ids) do
    notify(:fetch_issue_states_by_ids)

    case mode() do
      :rate_limited_refresh -> {:error, {:linear_rate_limited, 30_000}}
      _healthy -> {:ok, [issue()]}
    end
  end

  def create_comment(_issue_id, _body), do: :ok
  def update_issue_state(_issue_id, _state_name), do: :ok
  def graphql(_query, _variables \\ %{}, _opts \\ []), do: {:ok, %{}}

  defp mode, do: :persistent_term.get(@mode_key, :healthy)

  defp notify(event) do
    case :persistent_term.get(@recipient_key, nil) do
      pid when is_pid(pid) -> send(pid, {:linear_stub, event})
      _ -> :ok
    end
  end
end

defmodule SymphonyElixir.LinearRateLimitTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.RateLimit
  alias SymphonyElixir.LinearRateLimitTest.LinearClientStub

  @rate_limited_body %{
    "errors" => [
      %{
        "extensions" => %{
          "code" => "RATELIMITED",
          "http" => %{"headers" => %{}, "status" => 400},
          "meta" => %{
            "rateLimitResult" => %{
              "allowed" => false,
              "duration" => 3_600_000,
              "limit" => 2500,
              "remaining" => 0,
              "requested" => 1
            }
          },
          "statusCode" => 429,
          "type" => "ratelimited",
          "userError" => true
        },
        "message" => "Rate limit exceeded. Only 2500 requests are allowed per 1 hour."
      }
    ]
  }

  setup do
    RateLimit.clear()

    on_exit(fn ->
      RateLimit.clear()
      LinearClientStub.clear()
      Application.delete_env(:symphony_elixir, :linear_client_module)
    end)

    :ok
  end

  test "rate-limit pause caps at 10 minutes, never shortens, and expires" do
    assert RateLimit.pause(3_600_000) == 600_000
    assert RateLimit.remaining_ms() > 590_000

    assert RateLimit.pause(1_000) == 1_000
    assert RateLimit.remaining_ms() > 590_000
    assert {:rate_limited, _remaining} = RateLimit.check()

    RateLimit.clear()
    assert :ok = RateLimit.check()

    assert RateLimit.pause(50) == 50
    assert {:rate_limited, _remaining} = RateLimit.check()
    Process.sleep(80)
    assert :ok = RateLimit.check()
  end

  test "RATELIMITED 400 response trips the global breaker and short-circuits later requests" do
    parent = self()

    request_fun = fn _payload, _headers ->
      send(parent, :linear_http_request)
      {:ok, %{status: 400, body: @rate_limited_body}}
    end

    log =
      capture_log(fn ->
        assert {:error, {:linear_rate_limited, 600_000}} =
                 Client.graphql("query { viewer { id } }", %{}, request_fun: request_fun)
      end)

    assert log =~ "rate limited"
    assert_receive :linear_http_request

    # While paused, no HTTP request may be issued at all.
    assert {:error, {:linear_rate_limited, remaining_ms}} =
             Client.graphql("query { viewer { id } }", %{}, request_fun: request_fun)

    assert remaining_ms > 0 and remaining_ms <= 600_000
    refute_receive :linear_http_request, 50
  end

  test "plain HTTP 400 without RATELIMITED extension is not treated as rate limiting" do
    request_fun = fn _payload, _headers ->
      {:ok, %{status: 400, body: %{"errors" => [%{"message" => "bad query"}]}}}
    end

    capture_log(fn ->
      assert {:error, {:linear_api_status, 400}} =
               Client.graphql("query { viewer { id } }", %{}, request_fun: request_fun)
    end)

    assert :ok = RateLimit.check()
  end

  test "HTTP 429 responses trip the breaker with the default pause" do
    request_fun = fn _payload, _headers ->
      {:ok, %{status: 429, body: ""}}
    end

    capture_log(fn ->
      assert {:error, {:linear_rate_limited, pause_ms}} =
               Client.graphql("query { viewer { id } }", %{}, request_fun: request_fun)

      assert pause_ms == RateLimit.default_pause_ms()
    end)

    assert {:rate_limited, _remaining} = RateLimit.check()
  end

  test "continuation throttle config parses from WORKFLOW.md and rejects negatives" do
    assert Config.settings!().agent.continuation_min_turn_interval_ms in [nil, 0]

    write_workflow_file!(Workflow.workflow_file_path(), continuation_min_turn_interval_ms: 45_000)
    assert Config.settings!().agent.continuation_min_turn_interval_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), continuation_min_turn_interval_ms: -1)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "continuation_min_turn_interval_ms"
  end

  test "continuation throttle waits out the configured minimum turn interval" do
    issue = LinearClientStub.issue()

    turn_started_at_ms = System.monotonic_time(:millisecond)

    capture_log(fn ->
      assert :ok =
               AgentRunner.throttle_continuation_turn_for_test(
                 issue,
                 [continuation_min_turn_interval_ms: 120],
                 turn_started_at_ms
               )
    end)

    assert System.monotonic_time(:millisecond) - turn_started_at_ms >= 100

    # A turn that already outlasted the interval must not wait again.
    long_ago_ms = System.monotonic_time(:millisecond) - 10_000
    before_ms = System.monotonic_time(:millisecond)

    assert :ok =
             AgentRunner.throttle_continuation_turn_for_test(
               issue,
               [continuation_min_turn_interval_ms: 120],
               long_ago_ms
             )

    assert System.monotonic_time(:millisecond) - before_ms < 100
  end

  test "continuation check surfaces rate limiting without raising" do
    issue = LinearClientStub.issue()
    fetcher = fn _ids -> {:error, {:linear_rate_limited, 123}} end

    assert {:rate_limited, {:linear_rate_limited, 123}} =
             AgentRunner.continue_with_issue_for_test?(issue, fetcher)
  end

  test "rate limited dispatch-time refresh keeps the retry chain alive and dispatch resumes" do
    issue = LinearClientStub.issue()
    LinearClientStub.set_recipient(self())
    LinearClientStub.set_mode(:rate_limited_refresh)
    Application.put_env(:symphony_elixir, :linear_client_module, LinearClientStub)

    write_workflow_file!(Workflow.workflow_file_path(),
      poll_interval_ms: 3_600_000,
      codex_command: "/usr/bin/false app-server"
    )

    orchestrator_name = Module.concat(__MODULE__, :RateLimitedRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    retry_token = make_ref()

    :sys.replace_state(pid, fn state ->
      state
      |> Map.put(:claimed, MapSet.new([issue.id]))
      |> Map.put(:retry_attempts, %{
        issue.id => %{
          attempt: 3,
          timer_ref: nil,
          retry_token: retry_token,
          due_at_ms: System.monotonic_time(:millisecond),
          identifier: issue.identifier,
          error: "agent exited: previous failure",
          worker_host: nil,
          workspace_path: nil
        }
      })
    end)

    # Fire the retry: candidate poll succeeds but the dispatch-time issue
    # refresh hits RATELIMITED — exactly the sequence that killed the retry
    # chain in the 2026-07-21 incident.
    capture_log(fn ->
      send(pid, {:retry_issue, issue.id, retry_token})

      wait_until(fn ->
        match?(%{attempt: 4}, :sys.get_state(pid).retry_attempts[issue.id])
      end)
    end)

    now_ms = System.monotonic_time(:millisecond)

    assert %{attempt: 4, due_at_ms: due_at_ms, timer_ref: timer_ref, retry_token: next_retry_token} =
             :sys.get_state(pid).retry_attempts[issue.id]

    # The retry timer must still be alive...
    assert is_reference(timer_ref)
    assert is_integer(Process.read_timer(timer_ref))

    # ...and scheduled per the rate-limit retry-after hint (30s), not the
    # exponential failure backoff (80s for attempt 4).
    assert due_at_ms - now_ms > 25_000
    assert due_at_ms - now_ms <= 30_500

    # Rate limit lifts; the pending retry must resume the dispatch pipeline.
    LinearClientStub.set_mode(:healthy)
    flush_stub_messages()

    capture_log(fn ->
      send(pid, {:retry_issue, issue.id, next_retry_token})

      assert_receive {:linear_stub, :fetch_candidate_issues}, 2_000
      assert_receive {:linear_stub, :fetch_issue_states_by_ids}, 2_000

      # Dispatch resumed: either the agent is running, or it already spawned
      # and crashed (fake codex command), scheduling the next retry attempt.
      wait_until(
        fn ->
          state = :sys.get_state(pid)

          Map.has_key?(state.running, issue.id) or
            match?(%{attempt: attempt} when attempt >= 5, state.retry_attempts[issue.id])
        end,
        5_000
      )
    end)
  end

  defp wait_until(condition_fun, timeout_ms \\ 2_000) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(condition_fun, deadline_ms)
  end

  defp do_wait_until(condition_fun, deadline_ms) do
    cond do
      condition_fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline_ms ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(10)
        do_wait_until(condition_fun, deadline_ms)
    end
  end

  defp flush_stub_messages do
    receive do
      {:linear_stub, _event} -> flush_stub_messages()
    after
      0 -> :ok
    end
  end
end
