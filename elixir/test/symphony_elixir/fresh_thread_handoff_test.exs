defmodule SymphonyElixir.FreshThreadHandoffTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.FreshThreadHandoff

  @contract_hash String.duplicate("b", 64)

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-fresh-thread-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, ".symphony"))
    on_exit(fn -> File.rm_rf(workspace) end)
    %{workspace: workspace}
  end

  test "consumes a matching receipt exactly once", %{workspace: workspace} do
    write_receipt(workspace, %{
      "schemaVersion" => 1,
      "issue" => "CLA-42",
      "contractHash" => @contract_hash,
      "reason" => "late-mechanism",
      "requestedAt" => "2026-08-20T01:02:03Z"
    })

    assert {:ok, receipt} =
             FreshThreadHandoff.consume(workspace, issue(), @contract_hash)

    assert receipt.issue == "CLA-42"
    assert receipt.reason == "late-mechanism"
    assert receipt.requested_at == ~U[2026-08-20 01:02:03Z]
    refute File.exists?(receipt_path(workspace))
    assert :none = FreshThreadHandoff.consume(workspace, issue(), @contract_hash)
  end

  test "fails closed and preserves a stale or cross-issue receipt", %{workspace: workspace} do
    for {field, value, reason} <- [
          {"issue", "CLA-99", :issue},
          {"contractHash", String.duplicate("c", 64), :contract_hash},
          {"reason", "unknown", :reason}
        ] do
      payload = %{
        "schemaVersion" => 1,
        "issue" => "CLA-42",
        "contractHash" => @contract_hash,
        "reason" => "context-reset",
        "requestedAt" => "2026-08-20T01:02:03Z"
      }

      write_receipt(workspace, Map.put(payload, field, value))

      assert {:error, {:invalid_fresh_thread_receipt, ^reason}} =
               FreshThreadHandoff.consume(workspace, issue(), @contract_hash)

      assert File.exists?(receipt_path(workspace))
    end
  end

  test "rejects malformed receipt shapes, timestamps, and missing current authority", %{
    workspace: workspace
  } do
    write_receipt(workspace, ["not", "an", "object"])

    assert {:error, {:invalid_fresh_thread_receipt, :not_an_object}} =
             FreshThreadHandoff.consume(workspace, issue(), @contract_hash)

    payload = valid_payload() |> Map.put("requestedAt", "not-a-time")
    write_receipt(workspace, payload)

    assert {:error, {:invalid_fresh_thread_receipt, :requested_at}} =
             FreshThreadHandoff.consume(workspace, issue(), @contract_hash)

    write_receipt(workspace, valid_payload() |> Map.put("requestedAt", 123))

    assert {:error, {:invalid_fresh_thread_receipt, :requested_at}} =
             FreshThreadHandoff.consume(workspace, issue(), @contract_hash)

    write_receipt(workspace, valid_payload() |> Map.put("contractHash", 123))

    assert {:error, {:invalid_fresh_thread_receipt, :contract_hash_format}} =
             FreshThreadHandoff.consume(workspace, issue(), @contract_hash)

    write_receipt(workspace, valid_payload())

    assert {:error, {:invalid_fresh_thread_receipt, :contract_hash}} =
             FreshThreadHandoff.consume(workspace, issue(), nil)
  end

  test "surfaces receipt read and one-shot removal failures without losing the receipt", %{
    workspace: workspace
  } do
    path = receipt_path(workspace)
    directory = Path.dirname(path)
    write_receipt(workspace, valid_payload())
    File.chmod!(path, 0o000)

    try do
      assert {:error, {:fresh_thread_receipt_read_failed, _reason}} =
               FreshThreadHandoff.consume(workspace, issue(), @contract_hash)
    after
      File.chmod!(path, 0o600)
    end

    File.chmod!(directory, 0o500)

    try do
      assert {:error, {:fresh_thread_receipt_consume_failed, _reason}} =
               FreshThreadHandoff.consume(workspace, issue(), @contract_hash)

      assert File.exists?(path)
    after
      File.chmod!(directory, 0o700)
    end
  end

  defp write_receipt(workspace, payload) do
    File.write!(receipt_path(workspace), Jason.encode!(payload))
  end

  defp receipt_path(workspace), do: Path.join(workspace, FreshThreadHandoff.receipt_path())

  defp valid_payload do
    %{
      "schemaVersion" => 1,
      "issue" => "CLA-42",
      "contractHash" => @contract_hash,
      "reason" => "context-reset",
      "requestedAt" => "2026-08-20T01:02:03Z"
    }
  end

  defp issue do
    %Issue{
      id: "issue-42",
      identifier: "CLA-42",
      title: "Fresh thread",
      description: "Reset only with a valid receipt",
      state: "In Progress",
      labels: []
    }
  end
end
