defmodule SymphonyElixir.PromptArchive do
  @moduledoc """
  Persists the prompt injected into each Codex turn so the dashboard can show it.

  Symphony renders a turn prompt from `WORKFLOW.md` plus tracker text and hands
  it straight to the Codex app server, which means the only record of what an
  agent was actually told used to live inside Codex's own session files. Each
  turn writes one JSON record here instead, keyed by issue identifier, and the
  dashboard reads it back on demand -- the running snapshot only carries the
  reference, never the prompt body.
  """

  require Logger

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{LogFile, PathSafety}

  @keep_per_issue 20
  @basename_pattern ~r/\A[0-9A-Za-z._-]+\.json\z/
  @identifier_pattern ~r/\A[0-9A-Za-z._-]+\z/

  @type ref :: %{
          identifier: String.t(),
          basename: String.t(),
          path: Path.t(),
          turn: pos_integer(),
          chars: non_neg_integer(),
          at: DateTime.t()
        }

  @type section :: %{
          title: String.t(),
          origin: :issue | :template | :phase_context | :unknown,
          chars: non_neg_integer(),
          body: String.t()
        }

  @typedoc """
  One row of the archive index. Carries only what the basename encodes; the
  prompt body stays on disk until `read/2` is asked for it.
  """
  @type listing :: %{
          identifier: String.t(),
          basename: String.t(),
          turn: pos_integer() | nil,
          at: DateTime.t() | nil
        }

  @type record :: %{
          identifier: String.t(),
          basename: String.t(),
          issue_state: String.t() | nil,
          issue_title: String.t() | nil,
          turn: pos_integer(),
          attempt: term(),
          chars: non_neg_integer(),
          at: DateTime.t() | nil,
          workflow_file: String.t() | nil,
          issue_chars: non_neg_integer(),
          template_chars: non_neg_integer(),
          phase_context_chars: non_neg_integer(),
          phase: String.t() | nil,
          contract_hash: String.t() | nil,
          sections: [section()]
        }

  @doc """
  Writes one turn prompt to the archive and returns the reference to store on
  the running session. Archiving is best effort: a failure here is logged and
  never interrupts the turn it belongs to.
  """
  @spec record(Issue.t(), pos_integer(), String.t(), keyword()) :: {:ok, ref()} | {:error, term()}
  def record(%Issue{} = issue, turn_number, prompt, opts \\ [])
      when is_integer(turn_number) and turn_number > 0 and is_binary(prompt) do
    with {:ok, identifier} <- safe_identifier(issue.identifier) do
      at = Keyword.get(opts, :at, DateTime.utc_now())
      basename = "#{timestamp_slug(at)}-turn#{turn_number}.json"
      directory = Path.join(root(), identifier)
      path = Path.join(directory, basename)
      {offset, length} = description_range(prompt, issue.description)
      phase_context = Keyword.get(opts, :phase_context)

      payload =
        Jason.encode!(%{
          "identifier" => identifier,
          "issue_state" => issue.state,
          "issue_title" => issue.title,
          "turn" => turn_number,
          "attempt" => normalize_attempt(Keyword.get(opts, :attempt)),
          "at" => DateTime.to_iso8601(at),
          "workflow_file" => Keyword.get(opts, :workflow_file),
          "description_offset" => offset,
          "description_length" => length,
          "phase_context_offset" => field(phase_context, :offset),
          "phase_context_length" => field(phase_context, :length),
          "phase" => field(phase_context, :phase),
          "contract_hash" => field(phase_context, :contract_hash),
          "prompt" => prompt
        })

      # Pruning first keeps the archive at its ceiling rather than one over it,
      # and spares the write a directory listing it would only redo next turn.
      prune(identifier, @keep_per_issue - 1)

      with :ok <- File.mkdir_p(directory),
           :ok <- File.write(path, payload) do
        {:ok,
         %{
           identifier: identifier,
           basename: basename,
           path: path,
           turn: turn_number,
           chars: String.length(prompt),
           at: at
         }}
      end
    end
  rescue
    error ->
      Logger.error("Failed to archive turn prompt for #{issue.identifier}: #{Exception.message(error)}")
      {:error, :prompt_archive_write_failed}
  end

  @doc """
  Lists the archived prompts for one issue, oldest first.

  Everything in the listing is parsed from the basenames the archive itself
  writes, so building it costs one directory read and no file opens -- cheap
  enough to rebuild on every dashboard refresh. Reading from disk rather than
  from orchestrator state is the point: the index keeps working after the
  trail entry that announced a prompt has aged out, and across restarts.
  """
  @spec list(String.t()) :: [listing()]
  def list(identifier) when is_binary(identifier) do
    with {:ok, safe_identifier} <- safe_identifier(identifier),
         {:ok, entries} <- File.ls(Path.join(root(), safe_identifier)) do
      entries
      |> Enum.filter(&Regex.match?(@basename_pattern, &1))
      |> Enum.sort()
      |> Enum.map(&listing_entry(safe_identifier, &1))
    else
      _ -> []
    end
  end

  def list(_identifier), do: []

  defp listing_entry(identifier, basename) do
    %{
      identifier: identifier,
      basename: basename,
      turn: turn_from_basename(basename),
      at: at_from_basename(basename)
    }
  end

  defp turn_from_basename(basename) do
    case Regex.run(~r/-turn(\d+)\.json\z/, basename) do
      [_match, digits] -> String.to_integer(digits)
      _no_match -> nil
    end
  end

  defp at_from_basename(basename) do
    with [_match, slug] <- Regex.run(~r/\A(\d{8}T\d{6}Z)/, basename),
         {:ok, at, _offset} <- DateTime.from_iso8601(slug, Calendar.ISO, :basic) do
      at
    else
      _no_timestamp -> nil
    end
  end

  @doc """
  Reads one archived prompt back, split into sections tagged by origin.
  """
  @spec read(String.t(), String.t()) :: {:ok, record()} | {:error, term()}
  def read(identifier, basename) when is_binary(identifier) and is_binary(basename) do
    with {:ok, safe_identifier} <- safe_identifier(identifier),
         {:ok, safe_basename} <- safe_basename(basename),
         {:ok, path} <- resolve_path(safe_identifier, safe_basename),
         {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents) do
      {:ok, to_record(safe_identifier, safe_basename, decoded)}
    end
  end

  @doc """
  Splits a rendered prompt into `## ` sections, tagging each one as tracker text
  or workflow template based on where the issue description landed.
  """
  @spec sections(String.t(), non_neg_integer() | nil, non_neg_integer() | nil) :: [section()]
  def sections(prompt, description_offset, description_length) when is_binary(prompt) do
    sections(prompt, description_offset, description_length, nil, nil)
  end

  @doc false
  @spec sections(
          String.t(),
          non_neg_integer() | nil,
          non_neg_integer() | nil,
          non_neg_integer() | nil,
          non_neg_integer() | nil
        ) :: [section()]
  def sections(prompt, description_offset, description_length, phase_context_offset, phase_context_length)
      when is_binary(prompt) do
    boundaries = [{0, nil} | heading_offsets(prompt)]
    total = byte_size(prompt)

    boundaries
    |> Enum.zip(Enum.drop(boundaries, 1) ++ [{total, nil}])
    |> Enum.map(fn {{start, heading}, {next, _}} -> {start, heading, binary_part(prompt, start, next - start)} end)
    |> Enum.reject(fn {_start, _heading, body} -> String.trim(body) == "" end)
    |> Enum.map(fn {start, heading, body} ->
      %{
        title: section_title(heading, body),
        origin:
          origin_at(
            start,
            description_offset,
            description_length,
            phase_context_offset,
            phase_context_length
          ),
        chars: String.length(body),
        body: body
      }
    end)
  end

  @doc """
  Root directory of the archive, derived from the same logs root as the
  application log so `--logs-root` stays the single knob.
  """
  @spec root() :: Path.t()
  def root do
    :symphony_elixir
    |> Application.get_env(:log_file, LogFile.default_log_file())
    |> Path.expand()
    |> Path.dirname()
    |> Path.join("prompts")
  end

  defp resolve_path(identifier, basename) do
    candidate = Path.join([root(), identifier, basename])

    with {:ok, canonical} <- PathSafety.canonicalize(candidate),
         {:ok, canonical_root} <- PathSafety.canonicalize(root()) do
      if String.starts_with?(canonical, canonical_root <> "/") do
        {:ok, canonical}
      else
        {:error, {:prompt_archive_path_escape, candidate}}
      end
    end
  end

  defp to_record(identifier, basename, decoded) do
    prompt = Map.get(decoded, "prompt", "")
    offset = Map.get(decoded, "description_offset")
    length = Map.get(decoded, "description_length")
    phase_context_offset = Map.get(decoded, "phase_context_offset")
    phase_context_length = Map.get(decoded, "phase_context_length")
    sections = sections(prompt, offset, length, phase_context_offset, phase_context_length)

    %{
      identifier: identifier,
      basename: basename,
      issue_state: Map.get(decoded, "issue_state"),
      issue_title: Map.get(decoded, "issue_title"),
      turn: Map.get(decoded, "turn", 1),
      attempt: Map.get(decoded, "attempt"),
      chars: String.length(prompt),
      at: parse_timestamp(Map.get(decoded, "at")),
      workflow_file: Map.get(decoded, "workflow_file"),
      issue_chars: sum_chars(sections, :issue),
      template_chars: sum_chars(sections, :template) + sum_chars(sections, :unknown),
      phase_context_chars: sum_chars(sections, :phase_context),
      phase: Map.get(decoded, "phase"),
      contract_hash: Map.get(decoded, "contract_hash"),
      sections: sections
    }
  end

  defp sum_chars(sections, origin) do
    sections
    |> Enum.filter(&(&1.origin == origin))
    |> Enum.reduce(0, &(&1.chars + &2))
  end

  # Section origin is decided by byte offset rather than by re-matching text:
  # the description is interpolated verbatim, so its range is the only place
  # tracker prose can appear, and headings inside it must stay tracker-owned.
  defp origin_at(start, _offset, _length, phase_offset, phase_length)
       when is_integer(phase_offset) and is_integer(phase_length) and start >= phase_offset and
              start < phase_offset + phase_length,
       do: :phase_context

  defp origin_at(_start, offset, length, _phase_offset, _phase_length)
       when is_nil(offset) or is_nil(length),
       do: :unknown

  defp origin_at(start, offset, length, _phase_offset, _phase_length)
       when start >= offset and start < offset + length,
       do: :issue

  defp origin_at(_start, _offset, _length, _phase_offset, _phase_length), do: :template

  defp heading_offsets(prompt) do
    prompt
    |> String.split("\n")
    |> Enum.reduce({0, []}, fn line, {offset, acc} ->
      acc = if String.starts_with?(line, "## "), do: [{offset, line} | acc], else: acc
      {offset + byte_size(line) + 1, acc}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # The opening block has no heading of its own, so it borrows its first line --
  # in a rendered workflow prompt that is the document title.
  defp section_title(nil, body) do
    body
    |> String.split("\n")
    |> Enum.find("Prompt header", &(String.trim(&1) != ""))
    |> String.trim_leading("#")
    |> String.trim()
  end

  defp section_title(heading, _body), do: heading |> String.trim_leading("#") |> String.trim()

  # An issue with no description contributes nothing, so the empty range is the
  # truthful answer and every section is template-owned. A description that is
  # present but cannot be located is the only genuinely unattributable case:
  # the template mangled it, and guessing would mislabel whole sections.
  defp description_range(_prompt, description) when not is_binary(description) or description == "",
    do: {0, 0}

  defp description_range(prompt, description) do
    case :binary.match(prompt, description) do
      {offset, length} -> {offset, length}
      :nomatch -> {nil, nil}
    end
  end

  defp field(value, key) when is_map(value), do: Map.get(value, key)
  defp field(_value, _key), do: nil

  # Every turn writes ~40KB, so an unbounded archive quietly grows into the
  # hundreds of megabytes on a busy board. Keep the recent history per issue.
  defp prune(identifier, keep) do
    directory = Path.join(root(), identifier)

    case File.ls(directory) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(@basename_pattern, &1))
        |> Enum.sort(:desc)
        |> Enum.drop(keep)
        |> Enum.each(&File.rm(Path.join(directory, &1)))

      {:error, _reason} ->
        :ok
    end
  end

  defp safe_identifier(identifier) when is_binary(identifier) do
    if Regex.match?(@identifier_pattern, identifier) do
      {:ok, identifier}
    else
      {:error, {:invalid_issue_identifier, identifier}}
    end
  end

  defp safe_identifier(identifier), do: {:error, {:invalid_issue_identifier, identifier}}

  defp safe_basename(basename) do
    if Regex.match?(@basename_pattern, basename) do
      {:ok, basename}
    else
      {:error, {:invalid_prompt_basename, basename}}
    end
  end

  defp timestamp_slug(%DateTime{} = at) do
    at
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/[^0-9TZ]/, "")
  end

  defp normalize_attempt(attempt) when is_integer(attempt), do: attempt
  defp normalize_attempt(_attempt), do: nil

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> timestamp
      _ -> nil
    end
  end

  defp parse_timestamp(_value), do: nil
end
