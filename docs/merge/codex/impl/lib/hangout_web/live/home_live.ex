defmodule HangoutWeb.HomeLive do
  use HangoutWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, room: "", ttl: "", error: nil)}
  end

  @impl true
  def handle_event("create", %{"room" => room, "ttl" => ttl}, socket) do
    slug = room |> String.trim() |> String.downcase() |> String.replace(~r/[^a-z0-9-]/, "-") |> String.trim("-")
    slug = if slug == "", do: random_slug(), else: slug

    if Hangout.ChannelRegistry.valid?("#" <> slug) do
      query = if ttl in ["", "never"], do: "", else: "?ttl=#{ttl}"
      {:noreply, push_navigate(socket, to: "/" <> slug <> query)}
    else
      {:noreply, assign(socket, error: "Use 3-48 lowercase letters, numbers, and hyphens.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="home">
      <h1>Hangout</h1>
      <p class="contract">
        The room disappears from this server when everyone leaves.
        Anyone in the room can still copy or record what they see.
      </p>
      <.form for={%{}} phx-submit="create">
        <p><input name="room" value={@room} placeholder="calc-study" /></p>
        <p>
          <select name="ttl">
            <option value="never">Room expires: never</option>
            <option value="3600">Room expires: 1 hour</option>
            <option value="7200">Room expires: 2 hours</option>
            <option value="14400">Room expires: 4 hours</option>
            <option value="86400">Room expires: 1 day</option>
          </select>
        </p>
        <p><button type="submit">Create room</button></p>
      </.form>
      <p :if={@error} class="notice"><%= @error %></p>
    </main>
    """
  end

  defp random_slug do
    adjectives = ~w(quiet green bright small quick open)
    nouns = ~w(fox lamp room table river cloud)
    Enum.random(adjectives) <> "-" <> Enum.random(nouns) <> "-" <> Integer.to_string(:rand.uniform(999))
  end
end
