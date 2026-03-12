defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(runtime_total(@payload.runtime_totals, :total_tokens)) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(runtime_total(@payload.runtime_totals, :input_tokens)) %> / Out <%= format_int(runtime_total(@payload.runtime_totals, :output_tokens)) %>
              / Cache <%= format_int(runtime_total(@payload.runtime_totals, :cache_read_tokens) + runtime_total(@payload.runtime_totals, :cache_write_tokens)) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Pi runtime details</h2>
              <p class="section-copy">Live session stats reported directly by Pi RPC.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active Pi sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 880px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Model</th>
                    <th>Status</th>
                    <th>Cache</th>
                    <th>Cost</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td class="issue-id"><%= entry.issue_identifier %></td>
                    <td>
                      <div class="detail-stack">
                        <span><%= runtime_model_label(Map.get(entry, :runtime, %{})) %></span>
                        <span class="muted"><%= runtime_context_label(Map.get(entry, :runtime, %{})) %></span>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span><%= runtime_status_label(Map.get(entry, :runtime, %{})) %></span>
                        <span class="muted"><%= runtime_pending_label(Map.get(entry, :runtime, %{})) %></span>
                      </div>
                    </td>
                    <td class="numeric">
                      R <%= format_int(token_value(entry.tokens, :cache_read_tokens)) %> / W <%= format_int(token_value(entry.tokens, :cache_write_tokens)) %>
                    </td>
                    <td class="numeric"><%= format_money(map_value(entry, :cost_total, 0.0)) %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Runtime update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                          · <%= runtime_model_label(Map.get(entry, :runtime, %{})) %>
                          · <%= runtime_status_label(Map.get(entry, :runtime, %{})) %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(token_value(entry.tokens, :total_tokens)) %></span>
                        <span class="muted">In <%= format_int(token_value(entry.tokens, :input_tokens)) %> / Out <%= format_int(token_value(entry.tokens, :output_tokens)) %></span>
                        <span class="muted">R <%= format_int(token_value(entry.tokens, :cache_read_tokens)) %> / W <%= format_int(token_value(entry.tokens, :cache_write_tokens)) %> · <%= format_money(map_value(entry, :cost_total, 0.0)) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.runtime_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp format_money(value) when is_number(value), do: "$" <> :erlang.float_to_binary(value * 1.0, decimals: 3)
  defp format_money(_value), do: "n/a"

  defp runtime_total(map, key) when is_map(map), do: map_value(map, key, 0)
  defp runtime_total(_map, _key), do: 0

  defp token_value(tokens, key) when is_map(tokens), do: map_value(tokens, key, 0)
  defp token_value(_tokens, _key), do: 0

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp runtime_model_label(%{provider: provider, model_id: model_id, thinking_level: level})
       when is_binary(provider) and is_binary(model_id) and is_binary(level) do
    "#{provider}/#{model_id} · #{level}"
  end

  defp runtime_model_label(%{model_id: model_id, thinking_level: level})
       when is_binary(model_id) and is_binary(level) do
    "#{model_id} · #{level}"
  end

  defp runtime_model_label(%{model_id: model_id}) when is_binary(model_id), do: model_id
  defp runtime_model_label(_runtime), do: "n/a"

  defp runtime_context_label(%{context_window: context_window, auto_compaction_enabled: auto?})
       when is_integer(context_window) and context_window > 0 and is_boolean(auto?) do
    "window #{format_int(context_window)} · auto compact #{if(auto?, do: "on", else: "off")}"
  end

  defp runtime_context_label(%{context_window: context_window})
       when is_integer(context_window) and context_window > 0 do
    "window #{format_int(context_window)}"
  end

  defp runtime_context_label(_runtime), do: "window n/a"

  defp runtime_status_label(%{is_streaming: true, is_compacting: true}), do: "streaming · compacting"
  defp runtime_status_label(%{is_streaming: true}), do: "streaming"
  defp runtime_status_label(%{is_compacting: true}), do: "compacting"
  defp runtime_status_label(%{is_streaming: false}), do: "idle"
  defp runtime_status_label(_runtime), do: "status n/a"

  defp runtime_pending_label(%{pending_message_count: count}) when is_integer(count) and count >= 0,
    do: "pending #{count}"

  defp runtime_pending_label(_runtime), do: "pending n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end
end
