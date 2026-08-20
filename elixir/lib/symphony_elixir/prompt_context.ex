defmodule SymphonyElixir.PromptContext do
  @moduledoc """
  Loads a bounded, state-specific context packet immediately before a turn.

  The provider runs inside the issue workspace so generated harness tools and
  repository-local credentials resolve the same way they do for the agent.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue, Workspace}

  @contract_hash_pattern ~r/^- Contract hash: `([0-9a-f]{64})`$/im

  @type loaded :: %{
          text: String.t(),
          phase: String.t(),
          contract_hash: String.t(),
          offset: non_neg_integer() | nil,
          length: non_neg_integer()
        }

  @spec load(Path.t(), Issue.t(), String.t() | nil) :: {:ok, loaded() | nil} | {:error, term()}
  def load(workspace, %Issue{} = issue, worker_host \\ nil) when is_binary(workspace) do
    settings = Config.settings!().prompt_context

    case normalized_command(settings.command) do
      nil ->
        {:ok, nil}

      command ->
        with {:ok, phase} <- phase_for_state(issue.state),
             {:ok, {output, 0}} <-
               Workspace.run_command(
                 workspace,
                 command,
                 provider_env(issue, phase),
                 settings.timeout_ms,
                 worker_host
               ),
             {:ok, loaded} <- validate_output(output, phase, settings.max_chars) do
          {:ok, loaded}
        else
          {:ok, {output, status}} ->
            handle_failure(settings.required, {:prompt_context_command_failed, status, output}, issue)

          {:error, reason} ->
            handle_failure(settings.required, reason, issue)
        end
    end
  end

  @spec append(String.t(), loaded() | nil) :: {String.t(), loaded() | nil}
  def append(prompt, nil) when is_binary(prompt), do: {prompt, nil}

  def append(prompt, %{text: text} = loaded) when is_binary(prompt) and is_binary(text) do
    separator = if String.ends_with?(prompt, "\n"), do: "\n", else: "\n\n"
    section = "## Phase Context\n\n" <> text
    offset = byte_size(prompt) + byte_size(separator)
    {prompt <> separator <> section, %{loaded | offset: offset, length: byte_size(section)}}
  end

  defp provider_env(issue, phase) do
    %{
      "SYMPHONY_ISSUE_IDENTIFIER" => issue.identifier || "",
      "SYMPHONY_ISSUE_STATE" => issue.state || "",
      "SYMPHONY_CONTEXT_PHASE" => phase
    }
  end

  defp phase_for_state(state) when is_binary(state) do
    case state |> String.trim() |> String.downcase() do
      "todo" -> {:ok, "todo"}
      "in progress" -> {:ok, "build"}
      "rework" -> {:ok, "rework"}
      "agent review" -> {:ok, "review"}
      other -> {:error, {:unsupported_prompt_context_state, other}}
    end
  end

  defp phase_for_state(state), do: {:error, {:unsupported_prompt_context_state, state}}

  defp validate_output(output, phase, max_chars) do
    cond do
      not String.valid?(output) ->
        {:error, :prompt_context_invalid_utf8}

      String.trim(output) == "" ->
        {:error, :prompt_context_empty_output}

      String.length(output) > max_chars ->
        {:error, {:prompt_context_output_too_large, String.length(output), max_chars}}

      true ->
        case Regex.run(@contract_hash_pattern, output) do
          [_match, contract_hash] ->
            {:ok,
             %{
               text: String.trim_trailing(output) <> "\n",
               phase: phase,
               contract_hash: String.downcase(contract_hash),
               offset: nil,
               length: 0
             }}

          _ ->
            {:error, :prompt_context_contract_hash_missing}
        end
    end
  end

  defp handle_failure(true, reason, _issue), do: {:error, reason}

  defp handle_failure(false, reason, issue) do
    Logger.warning(
      "Optional prompt context unavailable issue_identifier=#{issue.identifier} " <>
        "state=#{inspect(issue.state)} reason=#{inspect(reason)}"
    )

    {:ok, nil}
  end

  defp normalized_command(command) when is_binary(command) do
    if String.trim(command) == "", do: nil, else: command
  end

  defp normalized_command(_command), do: nil
end
