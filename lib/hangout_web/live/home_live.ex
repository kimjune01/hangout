defmodule HangoutWeb.HomeLive do
  use HangoutWeb, :live_view

  alias Hangout.Naming

  @impl true
  def mount(_params, _session, socket) do
    case Application.get_env(:hangout, :default_room) do
      slug when is_binary(slug) and slug != "" ->
        {:ok, push_navigate(socket, to: "/#{slug}")}

      _ ->
        {:ok, assign(socket,
          room_name: "",
          ttl: "none",
          page_title: "Hangout"
        )}
    end
  end

  @impl true
  def handle_event("create_room", %{"room_name" => name, "ttl" => ttl}, socket) do
    slug = case String.trim(name) do
      "" -> generate_slug()
      s -> slugify(s)
    end

    if Hangout.ChannelRegistry.valid?("#" <> slug) do
      ttl_param = if ttl != "none", do: "?ttl=#{ttl}", else: ""
      {:noreply, push_navigate(socket, to: "/#{slug}#{ttl_param}")}
    else
      {:noreply, put_flash(socket, :error, "Invalid room name. Use 3-48 lowercase letters, digits, and hyphens.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container">
      <div class="home-form">
        <h1>#hangout</h1>
        <p class="tagline">Rooms exist while people are in them.</p>

        <%= if f = @flash["error"] do %>
          <div class="flash error">{f}</div>
        <% end %>

        <form phx-submit="create_room">
          <input
            type="text"
            name="room_name"
            value={@room_name}
            placeholder="Room name (leave blank for random)"
            autocomplete="off"
          />

          <select name="ttl">
            <option value="none">Room expires: never</option>
            <option value="3600">1 hour</option>
            <option value="7200">2 hours</option>
            <option value="14400">4 hours</option>
            <option value="86400">1 day</option>
          </select>

          <button type="submit">Create room</button>
        </form>

        <div class="social-contract">
          <p>No accounts. No history. No permanence.</p>
          <p>Anyone present can still copy what they see.</p>
        </div>
      </div>
    </div>
    """
  end

  defp generate_slug, do: Naming.random_slug()
  defp slugify(name), do: Naming.slugify(name)
end
