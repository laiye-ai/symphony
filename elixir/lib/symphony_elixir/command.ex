defmodule SymphonyElixir.Command do
  @moduledoc false

  @windows_script_extensions [".bat", ".cmd"]

  @spec run(Path.t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    {launcher, launcher_args} = invocation(executable, args)
    System.cmd(launcher, launcher_args, opts)
  end

  @spec open_port(Path.t(), [String.t()], keyword()) :: port()
  def open_port(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    {launcher, launcher_args} = invocation(executable, args)

    port_opts =
      opts
      |> Enum.reject(&match?({:args, _}, &1))
      |> Kernel.++(args: Enum.map(launcher_args, &String.to_charlist/1))

    Port.open({:spawn_executable, String.to_charlist(launcher)}, port_opts)
  end

  defp invocation(executable, args) do
    if windows?() and windows_script?(executable) do
      {command_processor!(), ["/d", "/c", executable | Enum.map(args, &escape_cmd_meta/1)]}
    else
      {executable, args}
    end
  end

  defp escape_cmd_meta(argument) do
    argument
    |> String.replace("^", "^^")
    |> String.replace(~r/([&|<>()])/, "^\\1")
  end

  defp windows_script?(executable) do
    executable
    |> Path.extname()
    |> String.downcase()
    |> Kernel.in(@windows_script_extensions)
  end

  defp command_processor! do
    System.get_env("ComSpec") || System.find_executable("cmd") || raise "Windows command processor not found"
  end

  defp windows?, do: match?({:win32, _}, :os.type())
end
