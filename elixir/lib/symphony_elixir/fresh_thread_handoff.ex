defmodule SymphonyElixir.FreshThreadHandoff do
  @moduledoc """
  Validates and consumes an agent-authored request for a fresh Codex thread.

  The fixed receipt path is workspace-local. A receipt is authoritative only
  for the matching issue and the contract hash injected into the completed
  turn; invalid or stale receipts fail closed and remain available to inspect.
  """

  alias SymphonyElixir.{Linear.Issue, Workspace}

  @receipt_path ".symphony/fresh-thread-handoff.json"
  @valid_reasons MapSet.new(["late-mechanism", "convergence", "context-reset"])
  @hash_pattern ~r/\A[0-9a-f]{64}\z/

  @type receipt :: %{
          issue: String.t(),
          contract_hash: String.t(),
          reason: String.t(),
          requested_at: DateTime.t()
        }

  @spec consume(Path.t(), Issue.t(), String.t() | nil, String.t() | nil) ::
          :none | {:ok, receipt()} | {:error, term()}
  def consume(workspace, %Issue{} = issue, contract_hash, worker_host \\ nil)
      when is_binary(workspace) do
    with {:ok, raw} <- read_receipt(workspace, worker_host),
         {:ok, receipt} <- validate_receipt(raw, issue, contract_hash),
         :ok <- remove_receipt(workspace, worker_host) do
      {:ok, receipt}
    else
      :none -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  @spec receipt_path() :: String.t()
  def receipt_path, do: @receipt_path

  defp read_receipt(workspace, worker_host) do
    command = "if [ -f #{@receipt_path} ]; then cat #{@receipt_path}; else exit 3; fi"

    case Workspace.run_command(workspace, command, %{}, 5_000, worker_host) do
      {:ok, {_output, 3}} -> :none
      {:ok, {output, 0}} -> Jason.decode(output)
      result -> {:error, {:fresh_thread_receipt_read_failed, result}}
    end
  end

  defp validate_receipt(decoded, issue, current_contract_hash) when is_map(decoded) do
    schema_version = Map.get(decoded, "schemaVersion")
    receipt_issue = Map.get(decoded, "issue")
    receipt_hash = decoded |> Map.get("contractHash") |> normalized_hash()
    reason = Map.get(decoded, "reason")

    with :ok <- require_equal(:schema_version, schema_version, 1),
         :ok <- require_equal(:issue, receipt_issue, issue.identifier),
         :ok <- require_hash(receipt_hash),
         :ok <- require_equal(:contract_hash, receipt_hash, normalized_hash(current_contract_hash)),
         :ok <- require_reason(reason),
         {:ok, requested_at} <- parse_requested_at(Map.get(decoded, "requestedAt", "")) do
      {:ok,
       %{
         issue: receipt_issue,
         contract_hash: receipt_hash,
         reason: reason,
         requested_at: requested_at
       }}
    else
      {:error, reason} -> {:error, {:invalid_fresh_thread_receipt, reason}}
    end
  end

  defp validate_receipt(_decoded, _issue, _current_contract_hash),
    do: {:error, {:invalid_fresh_thread_receipt, :not_an_object}}

  defp remove_receipt(workspace, worker_host) do
    case Workspace.run_command(workspace, "rm -f -- #{@receipt_path}", %{}, 5_000, worker_host) do
      {:ok, {_output, 0}} -> :ok
      result -> {:error, {:fresh_thread_receipt_consume_failed, result}}
    end
  end

  defp require_equal(_field, left, right) when left == right, do: :ok
  defp require_equal(field, _left, _right), do: {:error, field}

  defp require_hash(hash) when is_binary(hash) do
    if Regex.match?(@hash_pattern, hash), do: :ok, else: {:error, :contract_hash_format}
  end

  defp require_hash(_hash), do: {:error, :contract_hash_format}

  defp require_reason(reason) do
    if MapSet.member?(@valid_reasons, reason), do: :ok, else: {:error, :reason}
  end

  defp parse_requested_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, requested_at, 0} -> {:ok, requested_at}
      _ -> {:error, :requested_at}
    end
  end

  defp parse_requested_at(_value), do: {:error, :requested_at}

  defp normalized_hash(hash) when is_binary(hash), do: String.downcase(hash)
  defp normalized_hash(_hash), do: nil
end
