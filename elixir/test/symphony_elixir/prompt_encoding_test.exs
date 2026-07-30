defmodule SymphonyElixir.PromptEncodingTest do
  use SymphonyElixir.TestSupport

  # `清` is E6 B8 85. The trailing 0x85 is also the NEL byte, which PCRE matches
  # as `\R` when the regex runs in byte mode, so a naive line split cuts this
  # character in half.
  @nel_carrying_text "跟进清单"

  test "workflow parsing keeps multi-byte characters that carry newline-like bytes" do
    prompt = """
    # Symphony Workflow

    Follow-up findings go to the workpad `#{@nel_carrying_text}` and ride along to human review.

    Description:

    {{ issue.description }}
    """

    write_workflow_file!(Workflow.workflow_file_path(), prompt: prompt)

    assert {:ok, %{prompt_template: template}} = Workflow.load()
    assert String.valid?(template)
    assert String.contains?(template, @nel_carrying_text)
  end

  test "prompt builder renders a CJK-heavy issue description as valid UTF-8" do
    prompt = """
    You are working on Linear ticket `{{ issue.identifier }}`.

    Follow-up findings go to the workpad `#{@nel_carrying_text}` and ride along to human review.

    Description:

    {{ issue.description }}
    """

    write_workflow_file!(Workflow.workflow_file_path(), prompt: prompt)

    # Shaped like the real ticket that broke this path: all-Chinese and large
    # enough that the prompt runs well past 10 KB.
    description = String.duplicate("现场证据：Windows 上团队 gateway 停不掉导致端口永久冲突，切换团队后重试永远失败。\n", 120)

    issue = %Issue{
      id: "issue-cjk-prompt",
      identifier: "MT-1107",
      title: "修复 Windows 团队 gateway 停不掉导致端口永久冲突",
      description: description,
      state: "Agent Review",
      url: "https://example.org/issues/MT-1107",
      labels: ["repo:desktop", "lane:express", "type:business-logic", "bug"]
    }

    built = PromptBuilder.build_prompt(issue)

    assert String.valid?(built)
    assert byte_size(built) > 10_000
    assert String.contains?(built, @nel_carrying_text)
    assert String.contains?(built, description)

    # The whole point of the fix: this payload must survive JSON encoding.
    assert built |> Jason.encode!() |> Jason.decode!() == built
  end

  test "app server repairs invalid UTF-8 in a turn prompt instead of killing the turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-prompt-encoding-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1107")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-prompt-encoding.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-prompt-encoding.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1107"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1107"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-prompt-encoding",
        identifier: "MT-1107",
        title: "修复 Windows 团队 gateway 停不掉导致端口永久冲突",
        description: "全中文描述，用于验证 prompt 组装与发送路径",
        state: "Agent Review",
        url: "https://example.org/issues/MT-1107",
        labels: ["repo:desktop"]
      }

      # `清` (E6 B8 85) with its trailing byte lopped off, exactly the shape a
      # byte-level split leaves behind.
      prompt = "跟进" <> <<0xE6, 0xB8>> <> "\n单 follow-up findings"
      refute String.valid?(prompt)

      log =
        capture_log(fn ->
          assert {:ok, _result} = AppServer.run(workspace, prompt, issue)
        end)

      assert log =~ "Repaired invalid UTF-8 in Codex app-server message"
      assert log =~ "field=params.input.0.text"
      assert log =~ "first_invalid_byte_offset=6"

      sent_prompt =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&(&1 |> String.trim_leading("JSON:") |> Jason.decode!()))
        |> Enum.find_value(fn payload ->
          if payload["method"] == "turn/start" do
            get_in(payload, ["params", "input", Access.at(0), "text"])
          end
        end)

      assert String.valid?(sent_prompt)
      assert String.contains?(sent_prompt, "跟进")
      assert String.contains?(sent_prompt, "单 follow-up findings")
    after
      File.rm_rf(test_root)
    end
  end
end
