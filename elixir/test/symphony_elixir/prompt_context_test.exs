defmodule SymphonyElixir.PromptContextTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PromptContext

  @contract_hash String.duplicate("a", 64)

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-prompt-context-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    %{workspace: workspace}
  end

  test "loads the state phase and appends a separately bounded section", %{workspace: workspace} do
    command =
      "printf '# Task Context: %s\\n\\n- Phase: `%s`\\n- Contract hash: `#{@contract_hash}`\\n' " <>
        ~S{"$SYMPHONY_ISSUE_IDENTIFIER" "$SYMPHONY_CONTEXT_PHASE"}

    write_workflow_file!(Workflow.workflow_file_path(),
      prompt_context_command: command,
      prompt_context_required: true
    )

    issue = issue(%{state: "Agent Review"})

    assert {:ok, loaded} = PromptContext.load(workspace, issue)
    assert loaded.phase == "review"
    assert loaded.contract_hash == @contract_hash
    assert loaded.text =~ "Task Context: CLA-42"

    {prompt, attributed} = PromptContext.append("# Workflow\n", loaded)

    assert prompt =~ "## Phase Context\n\n# Task Context: CLA-42"
    assert attributed.offset == byte_size("# Workflow\n\n")
    assert attributed.length == byte_size("## Phase Context\n\n" <> loaded.text)

    for {state, phase} <- [{"Todo", "todo"}, {"Rework", "rework"}] do
      assert {:ok, state_context} = PromptContext.load(workspace, issue(%{state: state}))
      assert state_context.phase == phase
    end
  end

  test "required provider failures stop the turn while optional failures degrade to no context", %{
    workspace: workspace
  } do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt_context_command: "printf 'provider failed' >&2; exit 7",
      prompt_context_required: true
    )

    assert {:error, {:prompt_context_command_failed, 7, "provider failed"}} =
             PromptContext.load(workspace, issue())

    write_workflow_file!(Workflow.workflow_file_path(),
      prompt_context_command: "exit 7",
      prompt_context_required: false
    )

    log = capture_log(fn -> assert {:ok, nil} = PromptContext.load(workspace, issue()) end)
    assert log =~ "Optional prompt context unavailable"
  end

  test "rejects missing hashes and output beyond the configured attention budget", %{
    workspace: workspace
  } do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt_context_command: "printf 'no receipt'",
      prompt_context_required: true
    )

    assert {:error, :prompt_context_contract_hash_missing} =
             PromptContext.load(workspace, issue())

    command = "printf '%080d\\n- Contract hash: `#{@contract_hash}`\\n' 0"

    write_workflow_file!(Workflow.workflow_file_path(),
      prompt_context_command: command,
      prompt_context_required: true,
      prompt_context_max_chars: 64
    )

    assert {:error, {:prompt_context_output_too_large, actual, 64}} =
             PromptContext.load(workspace, issue())

    assert actual > 64
  end

  test "rejects unsupported states and invalid UTF-8 from a required provider", %{
    workspace: workspace
  } do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt_context_command: "printf '# Context\\n- Contract hash: `#{@contract_hash}`\\n'",
      prompt_context_required: true
    )

    assert {:error, {:unsupported_prompt_context_state, "gated"}} =
             PromptContext.load(workspace, issue(%{state: "Gated"}))

    assert {:error, {:unsupported_prompt_context_state, nil}} =
             PromptContext.load(workspace, issue(%{state: nil}))

    write_workflow_file!(Workflow.workflow_file_path(),
      prompt_context_command: "perl -e 'print pack(q(C), 255)'",
      prompt_context_required: true
    )

    assert {:error, :prompt_context_invalid_utf8} = PromptContext.load(workspace, issue())
  end

  test "config rejects a required provider without a command" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt_context_required: true)

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "prompt_context.command"
    assert message =~ "required"
  end

  defp issue(overrides \\ %{}) do
    Map.merge(
      %Issue{
        id: "issue-42",
        identifier: "CLA-42",
        title: "Context provider",
        description: "Use a bounded phase packet",
        state: "In Progress",
        labels: []
      },
      overrides
    )
  end
end
