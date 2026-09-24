defmodule SymphonyElixir.CommandTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Command
  import SymphonyElixir.TestSupport, only: [write_fake_executable!: 3]

  test "runs native executables directly" do
    executable = System.find_executable("elixir")

    assert is_binary(executable)
    assert {output, 0} = Command.run(executable, ["--version"])
    assert output =~ "Elixir"
  end

  if match?({:win32, _}, :os.type()) do
    test "runs Windows command scripts with argument boundaries and exit status" do
      root = Path.join(System.tmp_dir!(), "symphony-command-test-#{System.unique_integer([:positive])}")
      script = Path.join(root, "probe.cmd")
      File.mkdir_p!(root)
      File.write!(script, "@echo off\r\necho VALUE:%~1\r\necho COMMAND:%~2\r\nexit /b 7\r\n")
      on_exit(fn -> File.rm_rf(root) end)

      assert {output, 7} = Command.run(script, ["hello world", "printf ready 2>/dev/null & exit 0"])
      assert output =~ "VALUE:hello world"
      assert output =~ "COMMAND:printf ready 2>/dev/null & exit 0"
    end

    test "opens Windows command scripts as ports" do
      root = Path.join(System.tmp_dir!(), "symphony-command-port-test-#{System.unique_integer([:positive])}")
      script = Path.join(root, "probe.cmd")
      File.mkdir_p!(root)
      File.write!(script, "@echo off\r\necho READY\r\n")
      on_exit(fn -> File.rm_rf(root) end)

      port = Command.open_port(script, [])
      assert_receive {^port, {:data, output}}, 1_000
      assert to_string(output) =~ "READY"
    end

    test "portable fake executables preserve more than nine arguments" do
      root = Path.join(System.tmp_dir!(), "symphony-fake-command-test-#{System.unique_integer([:positive])}")
      executable = write_fake_executable!(root, "probe", "#!/bin/sh\nprintf 'COUNT:%s ARGS:%s\\n' \"$#\" \"$*\"\n")
      on_exit(fn -> File.rm_rf(root) end)

      args = Enum.map(1..14, &"arg#{&1}")
      assert {output, 0} = Command.run(executable, args)
      assert output =~ "COUNT:14 ARGS:#{Enum.join(args, " ")}"
    end

    test "portable fake executables preserve GitHub CLI query arguments" do
      root = Path.join(System.tmp_dir!(), "symphony-fake-gh-test-#{System.unique_integer([:positive])}")

      executable =
        write_fake_executable!(root, "gh", """
        #!/bin/sh
        printf 'ARGS:%s\\n' "$*"
        if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
          printf '101\\n102\\n'
        fi
        """)

      on_exit(fn -> File.rm_rf(root) end)

      args = [
        "pr",
        "list",
        "--repo",
        "openai/symphony",
        "--head",
        "feature/workpad",
        "--state",
        "open",
        "--json",
        "number",
        "--jq",
        ".[].number"
      ]

      assert {output, 0} = Command.run(executable, args)
      assert output =~ "ARGS:#{Enum.join(args, " ")}"
      assert output =~ "101\n102\n"
    end
  end
end
