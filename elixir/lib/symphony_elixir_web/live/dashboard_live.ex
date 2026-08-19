defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.

  The layout is master-detail: the rail lists every issue the orchestrator knows
  about, grouped so that anything needing a human sorts to the top, and the pane
  carries the full history for whichever one is selected. The selection lives in
  the query string so a stalled session can be linked to.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  require Logger

  alias SymphonyElixir.PromptArchive
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000
  # Commands, tool calls and searches are how the agent works, not what it did.
  # A run of them between two messages is one activity, so it collapses to one
  # row and the messages either side stay adjacent instead of being pushed a
  # screen apart.
  @groupable_kinds [:command, :tool, :search]
  # Two in a row are cheaper to read than to unfold; three is where a run starts
  # costing more than the click.
  @group_min_run 3
  # What the narrative view keeps: the agent's own words, the prompts it was
  # given, and anything that stopped it. `:failed` here means the turn went
  # down; a command that exited non-zero is `:command_failed` and stays out --
  # a grep with no matches exits 1 as part of ordinary work.
  @narrative_filter_kinds [:writing, :prompt, :awaiting_approval, :awaiting_input, :failed]
  # A session that has emitted nothing for this long has stopped making
  # progress, whatever its last event claimed it was doing.
  @stalled_after_seconds 300
  @slow_after_seconds 60

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok,
     assign(socket,
       selected: nil,
       lanes: [],
       expanded: MapSet.new(),
       prompt_view: nil,
       prompt_section: 0,
       trail_filter: :all,
       prompt_index_expanded: false,
       now: DateTime.utc_now()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:selected, params["issue"])
     |> assign(:prompt_index_expanded, false)
     |> close_prompt_view()
     |> refresh()}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("select", %{"issue" => issue}, socket) do
    {:noreply, push_patch(socket, to: "/?issue=#{URI.encode_www_form(issue)}")}
  end

  def handle_event("toggle_message", %{"key" => key}, socket) do
    expanded = socket.assigns.expanded

    toggled =
      if MapSet.member?(expanded, key) do
        MapSet.delete(expanded, key)
      else
        MapSet.put(expanded, key)
      end

    {:noreply, assign(socket, :expanded, toggled)}
  end

  def handle_event("open_prompt", %{"identifier" => identifier, "basename" => basename}, socket) do
    case PromptArchive.read(identifier, basename) do
      {:ok, record} ->
        {:noreply, assign(socket, prompt_view: record, prompt_section: 0)}

      {:error, reason} ->
        Logger.warning("Unable to open archived prompt #{identifier}/#{basename}: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_event("close_prompt", _params, socket) do
    {:noreply, close_prompt_view(socket)}
  end

  def handle_event("toggle_prompt_index", _params, socket) do
    {:noreply, assign(socket, :prompt_index_expanded, not socket.assigns.prompt_index_expanded)}
  end

  def handle_event("set_trail_filter", %{"filter" => "narrative"}, socket) do
    {:noreply, assign(socket, :trail_filter, :narrative)}
  end

  def handle_event("set_trail_filter", _params, socket) do
    {:noreply, assign(socket, :trail_filter, :all)}
  end

  def handle_event("select_prompt_section", %{"index" => index}, socket) do
    case Integer.parse(index) do
      {parsed, ""} -> {:noreply, assign(socket, :prompt_section, clamp_section(socket.assigns.prompt_view, parsed))}
      _ -> {:noreply, socket}
    end
  end

  defp refresh(socket) do
    payload = Presenter.dashboard_payload(orchestrator(), snapshot_timeout_ms(), socket.assigns.selected)
    now = DateTime.utc_now()

    # An unavailable snapshot carries an error instead of any issue lists, so
    # there is nothing to group or select.
    if payload[:error] do
      assign(socket, payload: payload, lanes: [], now: now)
    else
      lanes = lanes(payload, now)

      socket
      |> assign(payload: payload, lanes: lanes, now: now)
      |> resolve_selection(lanes)
    end
  end

  # Nothing selected -- or the selection has since finished and aged out -- so
  # fall back to whatever most deserves attention rather than leaving the pane
  # blank or silently jumping to an unrelated issue.
  defp resolve_selection(socket, lanes) do
    if socket.assigns.payload[:detail] do
      socket
    else
      case default_selection(lanes) do
        nil -> assign(socket, :selected, nil)
        identifier -> socket |> assign(:selected, identifier) |> reload_detail(identifier)
      end
    end
  end

  defp reload_detail(socket, identifier) do
    payload = Presenter.dashboard_payload(orchestrator(), snapshot_timeout_ms(), identifier)
    assign(socket, :payload, payload)
  end

  defp default_selection(lanes) do
    Enum.find_value(lanes, fn {_key, _label, rows} ->
      case rows do
        [%{id: identifier} | _rest] -> identifier
        _ -> nil
      end
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @payload[:error] do %>
      <section class="panel error-panel">
        <p class="error-title">Snapshot unavailable</p>
        <p class="error-copy"><%= @payload.error.code %>: <%= @payload.error.message %></p>
      </section>
    <% else %>
      <div class="shell">
        <header class="topbar">
          <span class="topbar-brand">Symphony</span>
          <span class="dot-label conn-live">
            <span class="dot dot-live"></span>
            live · <%= format_ago(@payload.generated_at, @now) %>
          </span>
          <span class="dot-label conn-offline">
            <span class="dot dot-danger"></span>
            disconnected · last seen <%= format_ago(@payload.generated_at, @now) %>
          </span>
          <span class="mono muted">
            <%= format_int(@payload.codex_totals.total_tokens) %> tok · <%= format_seconds(@payload.codex_totals.seconds_running) %>
          </span>
          <span class="mono muted"><%= rate_limit_summary(@payload.rate_limits) %></span>
        </header>

        <div class="split">
          <nav class="rail">
            <%= for {key, label, rows} <- @lanes, rows != [] do %>
              <p class={"lane-label lane-label-#{key}"}><%= label %> · <%= length(rows) %></p>
              <button
                :for={row <- rows}
                type="button"
                class={"rail-row#{if row.id == @selected, do: " rail-row-selected", else: ""}"}
                phx-click="select"
                phx-value-issue={row.id}
              >
                <span class={"dot dot-#{row.tone}"}></span>
                <span class="rail-body">
                  <span class="rail-head">
                    <span class="rail-id"><%= row.id %></span>
                    <span class={"rail-meta mono#{if row.tone in ~w(danger warning)a, do: " tone-#{row.tone}", else: ""}"}>
                      <%= row.meta %>
                    </span>
                  </span>
                  <span class="rail-sub"><%= row.summary %></span>
                </span>
              </button>
            <% end %>
          </nav>

          <section class="detail">
            <%= cond do %>
              <% @prompt_view -> %>
                <.prompt_reader view={@prompt_view} selected={@prompt_section} />
              <% @payload.detail -> %>
                <.detail
                  detail={@payload.detail}
                  now={@now}
                  expanded={@expanded}
                  trail_filter={@trail_filter}
                  prompt_index_expanded={@prompt_index_expanded}
                />
              <% true -> %>
                <p class="empty-state">No issues are being tracked right now.</p>
            <% end %>
          </section>
        </div>
      </div>
    <% end %>
    """
  end

  defp detail(assigns) do
    ~H"""
    <header class="detail-head">
      <div class="detail-head-row">
        <span class="detail-id"><%= @detail.issue_identifier %></span>
        <span class={"chip chip-#{detail_tone(@detail, @now)}"}><%= detail_status(@detail) %></span>
        <span :if={detail_context(@detail) != ""} class="muted"><%= detail_context(@detail) %></span>
      </div>
      <p :if={detail_title(@detail)} class="detail-title"><%= detail_title(@detail) %></p>
    </header>

    <.prompt_index
      :if={Map.get(@detail, :prompts, []) != []}
      prompts={@detail.prompts}
      expanded={@prompt_index_expanded}
    />

    <%= if @detail.running do %>
      <section class="metrics mono">
        <span><b><%= format_seconds(runtime_seconds(@detail.running.started_at, @now)) %></b> runtime</span>
        <span><b><%= @detail.running.turn_count %></b> turns</span>
        <span><b><%= format_int(@detail.running.tokens.total_tokens) %></b> tokens</span>
        <span :if={@detail.running.diff_stats}>
          <b class="tone-added">+<%= @detail.running.diff_stats.added %></b>
          <b class="tone-danger">−<%= @detail.running.diff_stats.removed %></b>
          in <%= @detail.running.diff_stats.files %> files
        </span>
        <span class={heartbeat_class(@detail.running.last_progress_at, @now)}>
          <b><%= format_ago(@detail.running.last_progress_at, @now) %></b> since last event
        </span>
      </section>

      <section :if={@detail.running.plan} class="detail-block">
        <div class="block-head">
          <span class="block-label">Plan</span>
          <span class="progress"><span class="progress-fill" style={progress_style(@detail.running.plan)}></span></span>
          <span class="mono muted"><%= @detail.running.plan.completed %>/<%= @detail.running.plan.total %></span>
        </div>
        <ul class="plan">
          <li :for={step <- @detail.running.plan.steps} class={"plan-step plan-step-#{step.status || "pending"}"}>
            <%= step.text %>
          </li>
        </ul>
      </section>

      <section class="detail-block detail-timeline">
        <div class="block-head">
          <p class="block-label">Timeline</p>
          <.trail_filter_toggle filter={@trail_filter} />
        </div>
        <ol class="trail">
          <li class={"trail-row trail-open trail-#{activity_kind(@detail.running)}"}>
            <span class="trail-time mono">now</span>
            <span class="trail-rail" aria-hidden="true"></span>
            <div class="trail-card">
              <p class="trail-head">
                <span class="trail-title-live"><%= activity_label(@detail.running) %></span>
                <span class="trail-meta mono">
                  <%= format_seconds(seconds_since(activity_since(@detail.running), @now) || 0) %> · in progress
                </span>
              </p>
              <p :if={activity_detail(@detail.running)} class="trail-body mono">
                <%= activity_detail(@detail.running) %>
              </p>
              <pre :if={show_stdout?(@detail.running)} class="stdout"><%= @detail.running.stdout_tail %></pre>
            </div>
          </li>

          <.trail_rows entries={@detail.running.activity_trail} expanded={@expanded} filter={@trail_filter} />
        </ol>
        <p class="block-footnote">
          Last <%= length(@detail.running.activity_trail) %> events · older tool steps age out before messages and prompts
        </p>
      </section>
    <% end %>

    <section :if={@detail.observed} class="detail-block">
      <p class="activity-label"><%= observed_headline(@detail.observed) %></p>
      <p class="muted"><%= observed_explainer(@detail.observed) %></p>
      <p :if={@detail.observed.labels != []} class="mono muted"><%= Enum.join(@detail.observed.labels, " · ") %></p>
    </section>

    <section :if={@detail.retry} class="detail-block">
      <p class="activity-label">Waiting to retry · attempt <%= @detail.retry.attempt %></p>
      <p class="muted"><%= @detail.retry.error || "no error recorded" %></p>
    </section>

    <%= if @detail.recent do %>
      <section class={history_block_class(@detail)}>
        <div class="block-head">
          <p class="block-label">
            Last session · ended <%= format_ago(@detail.recent.finished_at, @now) %>
          </p>
          <.trail_filter_toggle :if={show_recent_trail?(@detail)} filter={@trail_filter} />
        </div>
        <p :if={@detail.recent.reason} class="muted mono"><%= @detail.recent.reason %></p>
        <ol :if={show_recent_trail?(@detail)} class="trail">
          <.trail_rows entries={@detail.recent.activity_trail} expanded={@expanded} filter={@trail_filter} />
        </ol>
        <footer class="detail-foot mono muted">
          <span><%= format_seconds(@detail.recent.runtime_seconds) %> · <%= @detail.recent.turn_count %> turns</span>
          <span :if={@detail.recent.tokens}><%= format_int(@detail.recent.tokens.total_tokens) %> tok</span>
          <span :if={@detail.recent.diff_stats}>
            +<%= @detail.recent.diff_stats.added %> −<%= @detail.recent.diff_stats.removed %> · <%= @detail.recent.diff_stats.files %> files
          </span>
        </footer>
      </section>
    <% end %>

    <footer class="detail-links">
      <a href={"/api/v1/#{@detail.issue_identifier}"}>JSON details</a>
      <a :if={@detail.observed && @detail.observed.url} href={@detail.observed.url}>Linear</a>
      <span class="mono muted"><%= @detail.workspace.path %></span>
    </footer>
    """
  end

  defp trail_filter_toggle(assigns) do
    ~H"""
    <div class="trail-filter" role="group" aria-label="Timeline filter">
      <button type="button" class={trail_filter_class(@filter, :all)} phx-click="set_trail_filter" phx-value-filter="all">
        all
      </button>
      <button
        type="button"
        class={trail_filter_class(@filter, :narrative)}
        phx-click="set_trail_filter"
        phx-value-filter="narrative"
      >
        narrative
      </button>
    </div>
    """
  end

  defp trail_filter_class(current, value) do
    "trail-filter-option#{if current == value, do: " is-active", else: ""}"
  end

  defp filter_trail(entries, :narrative), do: Enum.filter(entries, &(&1.kind in @narrative_filter_kinds))
  defp filter_trail(entries, _filter), do: entries

  defp trail_rows(assigns) do
    assigns = assign(assigns, :items, assigns.entries |> filter_trail(assigns.filter) |> group_trail())

    ~H"""
    <%= for item <- @items do %>
      <%= case item do %>
        <% {:entry, entry} -> %>
          <.trail_entry entry={entry} expanded={@expanded} />
        <% {:group, run} -> %>
          <li class="trail-row trail-group">
            <span class="trail-time mono"><%= format_clock(List.first(run).at) %></span>
            <span class="trail-rail" aria-hidden="true"></span>
            <div class="trail-card">
              <button
                type="button"
                class="trail-group-head"
                aria-expanded={to_string(MapSet.member?(@expanded, group_key(run)))}
                phx-click="toggle_message"
                phx-value-key={group_key(run)}
              >
                <span class="trail-kind"><%= length(run) %> steps</span>
                <span class="trail-group-peek mono"><%= List.first(run).title %></span>
                <svg viewBox="0 0 16 16" width="14" height="14" fill="none" aria-hidden="true">
                  <path d="M4 6.5 8 10.5 12 6.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
                </svg>
              </button>
              <ol :if={MapSet.member?(@expanded, group_key(run))} class="trail-group-steps">
                <li :for={step <- run} class="trail-group-step">
                  <span class="mono"><%= format_clock(step.at) %></span>
                  <span class="trail-group-step-title mono"><%= step.title %></span>
                  <span :if={step.meta} class="mono"><%= step.meta %></span>
                </li>
              </ol>
            </div>
          </li>
      <% end %>
    <% end %>
    """
  end

  # A prompt is where a turn begins, so it renders as the boundary it is -- a
  # divider that slices the trail into turns -- rather than as one more card
  # competing with the events it introduced. The whole divider opens the
  # archived prompt.
  defp trail_entry(%{entry: %{kind: :prompt, prompt: %{identifier: identifier}}} = assigns)
       when is_binary(identifier) do
    ~H"""
    <li class="trail-row trail-prompt">
      <span class="trail-time mono"><%= format_clock(@entry.at) %></span>
      <span class="trail-rail" aria-hidden="true"></span>
      <button
        type="button"
        class="trail-turn-divider"
        phx-click="open_prompt"
        phx-value-identifier={@entry.prompt.identifier}
        phx-value-basename={@entry.prompt.basename}
      >
        <span class="trail-turn-label mono">
          turn <%= @entry.prompt.turn %> prompt · <%= format_int(@entry.prompt.chars) %> chars
        </span>
        <span class="trail-turn-rule" aria-hidden="true"></span>
        <span class="trail-turn-view">view</span>
      </button>
    </li>
    """
  end

  defp trail_entry(assigns) do
    ~H"""
    <li class={"trail-row trail-#{@entry.kind}"}>
      <span class="trail-time mono"><%= format_clock(@entry.at) %></span>
      <span class="trail-rail" aria-hidden="true"></span>
      <div class={"trail-card#{if expanded?(@expanded, @entry), do: " is-expanded", else: ""}"}>
        <p class="trail-head">
          <span class="trail-kind"><%= trail_kind_label(@entry.kind) %></span>
          <span :if={@entry.meta} class="trail-meta mono"><%= @entry.meta %></span>
        </p>
        <p
          class={"trail-body#{if expanded?(@expanded, @entry), do: " trail-body-expanded", else: ""}"}
          id={"body-#{trail_key(@entry)}"}
          phx-hook={if @entry.kind == :writing, do: "Clamp"}
        >
          <%= @entry.title %>
        </p>
        <button
          :if={@entry.kind == :writing}
          type="button"
          class="trail-toggle"
          aria-expanded={to_string(expanded?(@expanded, @entry))}
          aria-label={if expanded?(@expanded, @entry), do: "Collapse message", else: "Expand message"}
          phx-click="toggle_message"
          phx-value-key={trail_key(@entry)}
        >
          <svg viewBox="0 0 16 16" width="14" height="14" fill="none" aria-hidden="true">
            <path d="M4 6.5 8 10.5 12 6.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
          </svg>
        </button>
      </div>
    </li>
    """
  end

  # The reader replaces the detail pane rather than floating over it: the prompt
  # is long enough that reading it beside a live timeline means reading neither.
  defp prompt_reader(assigns) do
    assigns =
      assign(assigns,
        rows: outline_rows(assigns.view.sections),
        section: Enum.at(assigns.view.sections, assigns.selected)
      )

    ~H"""
    <header class="prompt-head">
      <button type="button" class="prompt-back" phx-click="close_prompt" aria-label="Back to timeline">
        <svg viewBox="0 0 16 16" width="14" height="14" fill="none" aria-hidden="true">
          <path d="M9.5 4 5.5 8l4 4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
      </button>
      <span class="detail-id"><%= @view.identifier %></span>
      <span class="chip">turn <%= @view.turn %> prompt</span>
      <span class="prompt-head-meta mono">
        <%= format_int(@view.chars) %> chars<%= if @view.issue_state, do: " · #{@view.issue_state}" %>
      </span>
    </header>

    <section class="prompt-origins">
      <span class="prompt-origin-key">
        <span class="prompt-dot prompt-dot-issue" aria-hidden="true"></span>
        tracker text <span class="mono"><%= format_int(@view.issue_chars) %></span>
      </span>
      <span class="prompt-origin-key">
        <span class="prompt-dot prompt-dot-template" aria-hidden="true"></span>
        workflow template <span class="mono"><%= format_int(@view.template_chars) %></span>
      </span>
      <span class="prompt-ratio" aria-hidden="true">
        <span class="prompt-ratio-issue" style={"width: #{percent_of(@view.issue_chars, @view.chars)}%"}></span>
      </span>
    </section>

    <div class="prompt-split">
      <nav class="prompt-outline">
        <%= for row <- @rows do %>
          <%= case row do %>
            <% {:label, origin} -> %>
              <p class="prompt-outline-group"><%= origin_label(origin) %></p>
            <% {:row, index, entry} -> %>
              <button
                type="button"
                class={"prompt-outline-row#{if index == @selected, do: " is-selected", else: ""}"}
                phx-click="select_prompt_section"
                phx-value-index={index}
              >
                <span class={"prompt-dot prompt-dot-#{entry.origin}"} aria-hidden="true"></span>
                <span class="prompt-outline-title"><%= entry.title %></span>
                <span class="prompt-outline-chars mono"><%= format_int(entry.chars) %></span>
              </button>
          <% end %>
        <% end %>
      </nav>

      <article :if={@section} class="prompt-section">
        <p class="prompt-section-head">
          <span class="prompt-section-title"><%= @section.title %></span>
          <span class={"prompt-tag prompt-tag-#{@section.origin}"}><%= origin_label(@section.origin) %></span>
        </p>
        <p class="prompt-section-meta mono">
          <%= format_int(@section.chars) %> chars · <%= percent_of(@section.chars, @view.chars) %>% of this turn
        </p>
        <pre class="prompt-body mono"><%= @section.body %></pre>
      </article>
    </div>
    """
  end

  # Lane order is the reading order: what needs a human, what is working, what is
  # queued, what is parked, what just finished.
  defp lanes(payload, now) do
    {attention, running} = Enum.split_with(payload.running, &needs_attention?(&1, now))
    {dispatch, parked} = Enum.split_with(payload.observed, & &1.active_state)

    List.flatten([
      {:attention, "Needs attention", Enum.map(attention, &running_row(&1, now))},
      stage_lanes(running, payload.active_states, now),
      {:retrying, "Retrying", Enum.map(payload.retrying, &retry_row/1)},
      {:dispatch, "Awaiting dispatch", Enum.map(dispatch, &observed_row/1)},
      parked_lanes(parked, payload.parked_states),
      {:recent, "Recently finished", Enum.map(finished_only(payload), &recent_row(&1, now))}
    ])
  end

  # Live sessions are grouped by the stage their issue is at in the tracker, in
  # the order the workflow declares them, so the rail mirrors the team's own
  # pipeline instead of a vocabulary invented here. Anything in a state the
  # config does not list still gets a lane rather than vanishing.
  defp stage_lanes(running, active_states, now) do
    by_state = Enum.group_by(running, & &1.state)
    known = Enum.filter(active_states, &Map.has_key?(by_state, &1))
    unknown = by_state |> Map.keys() |> Enum.reject(&(&1 in active_states)) |> Enum.sort()

    Enum.map(known ++ unknown, fn state ->
      {stage_lane_key(state), state, Enum.map(by_state[state], &running_row(&1, now))}
    end)
  end

  # Parked work is split by tracker state for the same reason live work is:
  # "Gated" wants a decision from you and "Human Review" wants an approval, and
  # one "Handed off" bucket hides which of the two is asking. Lane order follows
  # the configured list, so the queue the workflow treats as most urgent reads
  # first; a state nobody declared still gets a lane rather than vanishing.
  defp parked_lanes(parked, parked_states) do
    by_state = Enum.group_by(parked, & &1.state)
    known = Enum.filter(parked_states, &Map.has_key?(by_state, &1))
    unknown = by_state |> Map.keys() |> Enum.reject(&(&1 in parked_states)) |> Enum.sort_by(&to_string/1)

    Enum.map(known ++ unknown, fn state ->
      {"parked-#{stage_lane_key(state)}", parked_lane_label(state), Enum.map(by_state[state], &observed_row/1)}
    end)
  end

  defp parked_lane_label(state) when is_binary(state), do: state
  defp parked_lane_label(_state), do: "Handed off"

  defp stage_lane_key(state) do
    state
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> then(&"stage-#{&1}")
  end

  # A finished session does not stop the issue from being re-dispatched, so the
  # same issue can legitimately hold both a live session and a completed one.
  # The rail lists each issue once, in its most current lane; the finished
  # session still shows in the detail pane, which is where history belongs.
  defp finished_only(payload) do
    current =
      [payload.running, payload.retrying, payload.observed]
      |> Enum.concat()
      |> MapSet.new(& &1.issue_identifier)

    payload.recent
    |> Enum.reject(&MapSet.member?(current, &1.issue_identifier))
    |> Enum.uniq_by(& &1.issue_identifier)
  end

  defp needs_attention?(entry, now) do
    blocked_activity?(entry) or stalled?(entry, now)
  end

  defp blocked_activity?(%{activity: %{kind: kind}}), do: kind in [:awaiting_approval, :awaiting_input, :failed]
  defp blocked_activity?(_entry), do: false

  defp stalled?(entry, now) do
    case seconds_since(entry.last_progress_at, now) do
      seconds when is_integer(seconds) -> seconds >= @stalled_after_seconds
      _ -> false
    end
  end

  defp running_row(entry, now) do
    %{
      id: entry.issue_identifier,
      tone: running_tone(entry, now),
      summary: activity_label(entry),
      meta: format_ago(entry.last_progress_at, now)
    }
  end

  defp retry_row(entry) do
    %{
      id: entry.issue_identifier,
      tone: "muted",
      summary: "attempt #{entry.attempt} · #{entry.error || "no error recorded"}",
      meta: "queued"
    }
  end

  defp observed_row(entry) do
    %{
      id: entry.issue_identifier,
      tone: "muted",
      summary: entry.state || "unknown state",
      meta: dwell_label(entry)
    }
  end

  defp recent_row(entry, now) do
    %{
      id: entry.issue_identifier,
      tone: if(entry.outcome == :failed, do: "danger", else: "muted"),
      summary: "#{entry.outcome} · #{entry.turn_count} turns",
      meta: format_ago(entry.finished_at, now)
    }
  end

  defp running_tone(entry, now) do
    cond do
      blocked_activity?(entry) -> "warning"
      stalled?(entry, now) -> "danger"
      true -> "live"
    end
  end

  # An unwitnessed transition means the issue may have been parked long before
  # the orchestrator started, so the dwell time is shown as a lower bound.
  defp dwell_label(%{state_seconds: seconds} = entry) do
    prefix = if entry.state_since_exact, do: "", else: "≥"
    "#{prefix}#{format_seconds(seconds)}"
  end

  defp dwell_label(_entry), do: "n/a"

  defp detail_tone(detail, now) do
    cond do
      detail.running && blocked_activity?(detail.running) -> "warning"
      detail.running && stalled?(detail.running, now) -> "danger"
      detail.running -> "live"
      detail.recent && detail.recent.outcome == :failed -> "danger"
      true -> "muted"
    end
  end

  defp detail_status(%{status: "running"} = detail) do
    if blocked_activity?(detail.running), do: "needs attention", else: "running"
  end

  # "observed" is an internal word for "the tracker is the only thing that knows
  # anything about this". Say what the tracker actually says instead.
  defp detail_status(%{status: "observed", observed: %{state: state}}) when is_binary(state), do: state

  defp detail_status(%{status: status}), do: status

  defp detail_title(detail) do
    [detail.running, detail.observed, detail.recent]
    |> Enum.find_value(&(&1 && Map.get(&1, :title)))
  end

  defp detail_context(detail) do
    [detail.workspace.host, detail.observed && detail.observed.state]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp observed_headline(%{active_state: true}), do: "Eligible for dispatch, no session yet"
  defp observed_headline(_observed), do: "Handed off · no session will start"

  defp observed_explainer(%{active_state: true}) do
    "Symphony dispatches from this state, so it is waiting on capacity or a dispatch gate."
  end

  defp observed_explainer(_observed) do
    "This state is outside the orchestrator's active states; it is waiting on CI or a human."
  end

  defp activity_label(%{activity: %{label: label}}) when is_binary(label), do: label
  defp activity_label(entry), do: entry.last_message || to_string(entry.last_event || "n/a")

  defp activity_detail(%{activity: %{detail: detail}}) when is_binary(detail), do: detail
  defp activity_detail(_entry), do: nil

  defp activity_since(%{activity: %{since: since}}), do: since
  defp activity_since(entry), do: entry.started_at

  defp activity_kind(%{activity: %{kind: kind}}), do: kind
  defp activity_kind(_entry), do: :thinking

  # Keyed by content rather than position: the timeline is newest-first and
  # grows, so an index-based key would slide the expanded row onto a different
  # event every time an event arrives.
  defp trail_key(entry), do: "#{entry.at}-#{:erlang.phash2(entry.title)}"

  @spec group_trail([map()]) :: [{:entry, map()} | {:group, [map()]}]
  defp group_trail(entries) do
    entries
    |> Enum.chunk_by(&groupable?/1)
    |> Enum.flat_map(&collapse_run/1)
  end

  defp groupable?(%{kind: kind}), do: kind in @groupable_kinds
  defp groupable?(_entry), do: false

  defp collapse_run([head | _] = run) do
    if groupable?(head) and length(run) >= @group_min_run do
      [{:group, run}]
    else
      Enum.map(run, &{:entry, &1})
    end
  end

  defp group_key([head | _]), do: "group-#{trail_key(head)}"

  defp expanded?(expanded, entry), do: MapSet.member?(expanded, trail_key(entry))

  defp close_prompt_view(socket), do: assign(socket, prompt_view: nil, prompt_section: 0)

  defp clamp_section(%{sections: sections}, index) when is_list(sections) do
    index |> max(0) |> min(max(length(sections) - 1, 0))
  end

  defp clamp_section(_view, _index), do: 0

  # Sections keep document order so the outline reads like the prompt does; the
  # origin label is inserted wherever ownership changes hands instead.
  defp outline_rows(sections) do
    sections
    |> Enum.with_index()
    |> Enum.reduce({nil, []}, fn {section, index}, {previous_origin, acc} ->
      acc =
        if section.origin == previous_origin,
          do: acc,
          else: [{:label, section.origin} | acc]

      {section.origin, [{:row, index, section} | acc]}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # The archive spans every session an issue has had, and each session numbers
  # its turns from 1, so a much-redispatched issue reads as a wall of "T1"s.
  # Chips are grouped into runs -- a turn number that fails to increase starts
  # a new run -- and only the latest run shows by default, with the rest
  # behind a count. Each run is timestamped so ten runs of "T1" read as ten
  # dispatches rather than one broken counter.
  defp prompt_index(assigns) do
    runs = prompt_runs(assigns.prompts)

    assigns =
      assign(assigns,
        runs: if(assigns.expanded, do: runs, else: Enum.take(runs, -1)),
        earlier: length(runs) - 1
      )

    ~H"""
    <section class="prompt-index">
      <span class="prompt-index-label">prompts</span>
      <button
        :if={@earlier > 0}
        type="button"
        class="prompt-index-toggle"
        aria-expanded={to_string(@expanded)}
        phx-click="toggle_prompt_index"
      >
        <%= if @expanded, do: "hide earlier", else: "#{@earlier} earlier #{if @earlier == 1, do: "run", else: "runs"}" %>
      </button>
      <span :for={run <- @runs} class="prompt-run">
        <span class="prompt-run-time mono"><%= format_clock(List.first(run).at) %></span>
        <button
          :for={ref <- run}
          type="button"
          class="prompt-chip mono"
          phx-click="open_prompt"
          phx-value-identifier={ref.identifier}
          phx-value-basename={ref.basename}
          title={prompt_chip_title(ref)}
        >
          <%= prompt_chip_label(ref) %>
        </button>
      </span>
    </section>
    """
  end

  defp prompt_runs(prompts) do
    prompts
    |> Enum.reduce([], fn
      %{turn: turn} = ref, [[%{turn: previous_turn} | _rest_of_run] = run | earlier_runs]
      when is_integer(previous_turn) and is_integer(turn) and turn > previous_turn ->
        [[ref | run] | earlier_runs]

      ref, runs ->
        [[ref] | runs]
    end)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
  end

  defp prompt_chip_label(%{turn: turn}) when is_integer(turn), do: "T#{turn}"
  defp prompt_chip_label(_ref), do: "?"

  defp prompt_chip_title(%{at: at}) when is_binary(at), do: at
  defp prompt_chip_title(%{basename: basename}), do: basename

  defp origin_label(:issue), do: "tracker text"
  defp origin_label(:template), do: "workflow template"
  defp origin_label(_origin), do: "origin unknown"

  defp percent_of(_part, total) when not is_integer(total) or total <= 0, do: 0

  defp percent_of(part, total) when is_integer(part), do: Float.round(part * 100 / total, 1)

  defp percent_of(_part, _total), do: 0

  defp trail_kind_label(:command), do: "command"
  defp trail_kind_label(:failed), do: "failed"
  defp trail_kind_label(:command_failed), do: "failed"
  defp trail_kind_label(:edit), do: "file change"
  defp trail_kind_label(:writing), do: "agent message"
  defp trail_kind_label(:tool), do: "tool"
  defp trail_kind_label(:search), do: "web search"
  defp trail_kind_label(:awaiting_approval), do: "approval"
  defp trail_kind_label(:awaiting_input), do: "input"
  defp trail_kind_label(:turn_done), do: "turn"
  defp trail_kind_label(:starting), do: "session"
  defp trail_kind_label(_kind), do: "turn"

  # Captured output belongs to the command that produced it. Once the session
  # has moved on to reasoning, that buffer is stale, and showing it puts the
  # largest block on the page in service of something no longer happening.
  defp show_stdout?(entry) do
    activity_kind(entry) == :command and entry.stdout_tail not in [nil, ""]
  end

  # An issue can hold a finished session and a live one at once, and only one of
  # them can own the pane's scroll area. The live timeline wins: it is what the
  # session is doing now. Two unbounded trails in one column is also what breaks
  # the layout -- the history block cannot shrink, so it eats the height the
  # timeline was supposed to grow into and the timeline collapses to nothing.
  defp show_recent_trail?(detail) do
    is_nil(detail.running) and detail.recent.activity_trail != []
  end

  defp history_block_class(detail) do
    if show_recent_trail?(detail), do: "detail-block detail-timeline", else: "detail-block"
  end

  defp progress_style(%{completed: completed, total: total}) when is_integer(total) and total > 0 do
    "width: #{round(completed / total * 100)}%"
  end

  defp progress_style(_plan), do: "width: 0%"

  defp heartbeat_class(last_progress_at, now) do
    case seconds_since(last_progress_at, now) do
      nil -> "muted"
      seconds when seconds >= @stalled_after_seconds -> "tone-danger"
      seconds when seconds >= @slow_after_seconds -> "tone-warning"
      _ -> "tone-live"
    end
  end

  defp rate_limit_summary(nil), do: "rate limits n/a"

  defp rate_limit_summary(rate_limits) when is_map(rate_limits) do
    case Enum.find_value(rate_limits, &window_usage/1) do
      nil -> "rate limits ok"
      usage -> usage
    end
  end

  defp rate_limit_summary(_rate_limits), do: "rate limits n/a"

  defp window_usage({name, %{} = window}) do
    case Enum.find_value(["used_percent", "usedPercent"], &Map.get(window, &1)) do
      percent when is_number(percent) -> "#{name} #{round(percent)}%"
      _ -> nil
    end
  end

  defp window_usage(_entry), do: nil

  defp runtime_seconds(started_at, now), do: seconds_since(started_at, now) || 0

  defp format_ago(timestamp, now) do
    case seconds_since(timestamp, now) do
      nil -> "n/a"
      seconds -> "#{format_seconds(seconds)} ago"
    end
  end

  defp format_clock(nil), do: "--:--:--"

  defp format_clock(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> parsed |> DateTime.to_time() |> Time.to_string() |> String.slice(0, 8)
      _ -> "--:--:--"
    end
  end

  defp format_clock(_timestamp), do: "--:--:--"

  defp seconds_since(nil, _now), do: nil

  defp seconds_since(timestamp, %DateTime{} = now) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> max(0, DateTime.diff(now, parsed, :second))
      _ -> nil
    end
  end

  defp seconds_since(%DateTime{} = timestamp, %DateTime{} = now), do: max(0, DateTime.diff(now, timestamp, :second))
  defp seconds_since(_timestamp, _now), do: nil

  defp format_seconds(seconds) when is_number(seconds) do
    whole = max(trunc(seconds), 0)

    cond do
      whole >= 3_600 -> "#{div(whole, 3_600)}h #{div(rem(whole, 3_600), 60)}m"
      whole >= 60 -> "#{div(whole, 60)}m #{rem(whole, 60)}s"
      true -> "#{whole}s"
    end
  end

  defp format_seconds(_seconds), do: "n/a"

  defp format_int(value) when is_integer(value) and value >= 1_000_000 do
    "#{Float.round(value / 1_000_000, 2)}M"
  end

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp orchestrator, do: Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator

  defp snapshot_timeout_ms, do: Endpoint.config(:snapshot_timeout_ms) || 15_000

  defp schedule_runtime_tick, do: Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
end
