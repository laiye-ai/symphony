defmodule SymphonyElixir.PromptArchiveTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PromptArchive

  @description """
  ## Issue Facts
  Gateway must not install channel dependencies.

  ## Non-Goals
  Nothing about the downloader.
  """

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-prompt-archive-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:symphony_elixir, :log_file)
    Application.put_env(:symphony_elixir, :log_file, Path.join(root, "log/symphony.log"))

    on_exit(fn ->
      if previous do
        Application.put_env(:symphony_elixir, :log_file, previous)
      else
        Application.delete_env(:symphony_elixir, :log_file)
      end

      File.rm_rf(root)
    end)

    %{root: root}
  end

  defp issue(overrides \\ %{}) do
    Map.merge(
      %Issue{
        id: "issue-1",
        identifier: "MT-1",
        title: "Prompt archive",
        description: @description,
        state: "Agent Review"
      },
      overrides
    )
  end

  defp prompt(description) do
    """
    # Symphony Workflow

    Issue context:
    - Identifier: `MT-1`

    Description:

    #{description}
    ## Operating Contract
    Read the issue body as the result contract.

    ## Validation Policy
    Run the narrowest proof.
    """
  end

  test "round trips a turn prompt and tags each section with its origin" do
    {:ok, ref} = PromptArchive.record(issue(), 1, prompt(@description), attempt: 2)

    assert ref.turn == 1
    assert File.exists?(ref.path)

    {:ok, record} = PromptArchive.read(ref.identifier, ref.basename)

    assert record.turn == 1
    assert record.attempt == 2
    assert record.issue_state == "Agent Review"

    origins = Map.new(record.sections, &{&1.title, &1.origin})

    assert origins["Issue Facts"] == :issue
    assert origins["Non-Goals"] == :issue
    assert origins["Operating Contract"] == :template
    assert origins["Validation Policy"] == :template
    # The preamble is everything before the first heading, which is the rendered
    # template header rather than anything the tracker supplied.
    assert origins["Symphony Workflow"] == :template

    assert record.issue_chars > 0
    assert record.template_chars > record.issue_chars
    assert record.issue_chars + record.template_chars == record.chars
  end

  test "lists archived prompts oldest first from basenames alone" do
    {:ok, first} = PromptArchive.record(issue(), 1, prompt(@description), at: ~U[2026-07-31 08:00:00Z])
    {:ok, second} = PromptArchive.record(issue(), 2, prompt(@description), at: ~U[2026-07-31 08:05:00Z])

    assert [one, two] = PromptArchive.list("MT-1")
    assert one.basename == first.basename
    assert two.basename == second.basename
    assert {one.turn, two.turn} == {1, 2}
    assert one.at == ~U[2026-07-31 08:00:00Z]
    assert one.identifier == "MT-1"
  end

  test "listing an issue with no archive answers empty rather than erroring" do
    assert PromptArchive.list("MT-NONE") == []
    assert PromptArchive.list("../escape") == []
    assert PromptArchive.list(nil) == []
  end

  test "lists a record whose basename encodes no turn or timestamp without inventing them" do
    {:ok, _ref} = PromptArchive.record(issue(), 1, prompt(@description), at: ~U[2026-07-31 08:00:00Z])
    File.write!(Path.join([PromptArchive.root(), "MT-1", "hand-written.json"]), "{}")

    assert Enum.any?(PromptArchive.list("MT-1"), fn entry ->
             entry.basename == "hand-written.json" and is_nil(entry.turn) and is_nil(entry.at)
           end)
  end

  test "marks every section unknown when the description is present but was not injected verbatim" do
    {:ok, ref} = PromptArchive.record(issue(%{description: "## Rewritten\nnot in the prompt\n"}), 1, prompt(@description))
    {:ok, record} = PromptArchive.read(ref.identifier, ref.basename)

    assert Enum.all?(record.sections, &(&1.origin == :unknown))
    assert record.issue_chars == 0
  end

  test "attributes everything to the template when the issue carries no description" do
    for description <- [nil, ""] do
      {:ok, ref} = PromptArchive.record(issue(%{description: description}), 1, "Continuation guidance:\n\n- Resume from the workspace.\n")

      {:ok, record} = PromptArchive.read(ref.identifier, ref.basename)

      assert Enum.all?(record.sections, &(&1.origin == :template))
      assert record.issue_chars == 0
      assert record.template_chars == record.chars
    end
  end

  test "titles a heading-less opening block rather than rendering it nameless" do
    [header | _rest] = PromptArchive.sections("\n\n# Symphony Workflow\ncontext\n\n## Handoff\ndone\n", 0, 0)

    assert header.title == "Symphony Workflow"
    # A prompt with nothing in it produces no outline rows at all.
    assert PromptArchive.sections("   \n\n", 0, 0) == []
  end

  test "reports a write it could not perform instead of taking the turn down with it" do
    assert {:error, :prompt_archive_write_failed} = PromptArchive.record(issue(), 1, "broken " <> <<0xFF>>)
    assert {:error, {:invalid_issue_identifier, nil}} = PromptArchive.record(issue(%{identifier: nil}), 1, "fine")
  end

  test "reads a record whose metadata is missing or malformed" do
    {:ok, ref} = PromptArchive.record(issue(), 1, prompt(@description))

    File.write!(ref.path, Jason.encode!(%{"prompt" => "## Only\nbody\n", "at" => "not-a-timestamp"}))

    {:ok, record} = PromptArchive.read(ref.identifier, ref.basename)

    assert record.at == nil
    assert record.turn == 1
    assert record.attempt == nil
    assert [%{title: "Only", origin: :unknown}] = record.sections

    # A record written before the timestamp existed at all still opens.
    File.write!(ref.path, Jason.encode!(%{"prompt" => "## Only\nbody\n", "turn" => 3}))

    assert {:ok, %{at: nil, turn: 3}} = PromptArchive.read(ref.identifier, ref.basename)
  end

  test "keeps section bodies intact so the reader shows the injected text" do
    {:ok, ref} = PromptArchive.record(issue(), 2, prompt(@description))
    {:ok, record} = PromptArchive.read(ref.identifier, ref.basename)

    section = Enum.find(record.sections, &(&1.title == "Validation Policy"))

    assert section.body =~ "Run the narrowest proof."
    assert section.chars == String.length(section.body)
  end

  test "refuses identifiers and basenames that would escape the archive root" do
    assert {:error, {:invalid_issue_identifier, _}} = PromptArchive.read("../../etc", "x.json")
    assert {:error, {:invalid_prompt_basename, _}} = PromptArchive.read("MT-1", "../../etc/passwd")
    assert {:error, {:invalid_prompt_basename, _}} = PromptArchive.read("MT-1", "notes.md")
  end

  test "prunes the oldest turns so a long-lived board cannot fill the disk" do
    for turn <- 1..25 do
      {:ok, _ref} =
        PromptArchive.record(issue(), turn, prompt(@description), at: DateTime.add(~U[2026-08-07 00:00:00Z], turn, :second))
    end

    files = Path.join([PromptArchive.root(), "MT-1"]) |> File.ls!() |> Enum.sort()

    assert length(files) == 20
    # Oldest first by name, so pruning must have dropped turns 1 through 5.
    refute Enum.any?(files, &String.ends_with?(&1, "turn1.json"))
    assert Enum.any?(files, &String.ends_with?(&1, "turn25.json"))
  end
end
