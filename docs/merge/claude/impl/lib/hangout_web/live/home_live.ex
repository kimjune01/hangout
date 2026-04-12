defmodule HangoutWeb.HomeLive do
  use Phoenix.LiveView

  @adjectives ~w(quiet green bright calm swift bold dark warm cool soft)
  @nouns ~w(fox lamp river cloud storm wind leaf spark wave flame)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket,
      room_name: "",
      ttl: "none",
      page_title: "Hangout"
    )}
  end

  @impl true
  def handle_event("create_room", %{"room_name" => name, "ttl" => ttl}, socket) do
    slug =
      case String.trim(name) do
        "" -> generate_slug()
        s -> slugify(s)
      end

    if Hangout.IRC.Parser.valid_channel_name?("#" <> slug) do
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
        <h1 style="font-size: 2rem; margin-bottom: 0.5rem;">Hangout</h1>
        <p style="color: #8b949e; margin-bottom: 2rem;">Ephemeral chat rooms. No signup.</p>

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

        <div class="social-contract" style="margin-top: 2rem;">
          <p>The room disappears from this server when everyone leaves.</p>
          <p>Anyone in the room can still copy or record what they see.</p>
        </div>
      </div>
    </div>
    """
  end

  defp generate_slug do
    adj = Enum.random(@adjectives)
    noun = Enum.random(@nouns)
    num = :rand.uniform(99)
    "#{adj}-#{noun}-#{num}"
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end
end
