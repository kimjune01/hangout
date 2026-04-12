defmodule HangoutWeb.SmokeTest do
  @moduledoc """
  End-to-end smoke tests: LiveView flows + cross-protocol (IRC ↔ browser).
  """
  use HangoutWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Hangout.{ChannelServer, Participant}

  @irc_port Application.compile_env(:hangout, :irc_port, 16667)

  # --- LiveView E2E ---

  describe "home page" do
    test "renders and creates a room", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")
      assert html =~ "#hangout"
      assert html =~ "Rooms exist while people are in them"

      # Submit form — should redirect to room
      view
      |> form("form", %{room_name: "smoke-test", ttl: "none"})
      |> render_submit()

      assert_redirect(view, "/smoke-test")
    end

    test "auto-generates slug when name is blank", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> form("form", %{room_name: "", ttl: "none"})
      |> render_submit()

      {path, _} = assert_redirect(view)
      assert path =~ ~r"^/[a-z]+-[a-z]+-\d+$"
    end
  end

  describe "room page" do
    test "renders nick prompt before join", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/smoke-room")
      assert html =~ "#smoke-room"
      assert html =~ "Step in"
      assert html =~ "room disappears"
    end

    test "join room with nick", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/smoke-join")

      html =
        view
        |> form("form", %{nick: "smoker"})
        |> render_submit()

      # After join, should see the input bar with nick
      assert html =~ "smoker"
      assert html =~ "message-input"
    end

    test "send and receive messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/smoke-msg")

      # Join
      view |> form("form", %{nick: "alice-smoke"}) |> render_submit()

      # Send a message
      html =
        view
        |> form("form[phx-submit=send_message]", %{body: "hello smoke test"})
        |> render_submit()

      # Message should appear in the buffer (via PubSub round-trip)
      assert render(view) =~ "hello smoke test"
    end

    test "room ended state", %{conn: conn} do
      # Create a room, join, end it
      {:ok, view, _} = live(conn, "/smoke-end")
      view |> form("form", %{nick: "ender-smoke"}) |> render_submit()

      # End the room from the ChannelServer directly
      {:ok, snapshot} = ChannelServer.snapshot("#smoke-end")
      # Find our token — first joiner is moderator
      ChannelServer.end_room("#smoke-end", "ender-smoke")

      # LiveView should show room ended
      html = render(view)
      assert html =~ "Room ended" or html =~ "room-ended"
    end

    test "flash error on invalid nick", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/smoke-badnick")

      html =
        view
        |> form("form", %{nick: "123invalid"})
        |> render_submit()

      assert html =~ "Invalid nick"
    end
  end

  # --- Cross-protocol: IRC ↔ LiveView ---

  describe "cross-protocol" do
    test "IRC message appears in LiveView", %{conn: conn} do
      # LiveView user joins
      {:ok, view, _} = live(conn, "/xproto-test")
      view |> form("form", %{nick: "browser-user"}) |> render_submit()

      # IRC user joins same room and sends a message
      irc = irc_connect()
      irc_register(irc, "irc-user")
      irc_send(irc, "JOIN #xproto-test")
      irc_recv_until(irc, "366")

      irc_send(irc, "PRIVMSG #xproto-test :hello from IRC!")
      Process.sleep(300)

      # LiveView should see the message
      html = render(view)
      assert html =~ "hello from IRC!"
      assert html =~ "irc-user"

      :gen_tcp.close(irc)
    end

    test "LiveView message appears on IRC", %{conn: conn} do
      # IRC user joins first
      irc = irc_connect()
      irc_register(irc, "irc-watcher")
      irc_send(irc, "JOIN #xproto-test2")
      irc_recv_until(irc, "366")

      # LiveView user joins and sends
      {:ok, view, _} = live(conn, "/xproto-test2")
      view |> form("form", %{nick: "browser-sender"}) |> render_submit()
      Process.sleep(200)
      irc_recv_all(irc)  # drain join event

      view
      |> form("form[phx-submit=send_message]", %{body: "hello from browser!"})
      |> render_submit()

      Process.sleep(300)
      output = irc_recv_all(irc)
      assert output =~ "hello from browser!"

      :gen_tcp.close(irc)
    end
  end

  # --- IRC helpers ---

  defp irc_connect do
    {:ok, sock} = :gen_tcp.connect(~c"localhost", @irc_port, [:binary, active: false, packet: :line])
    sock
  end

  defp irc_send(sock, line), do: :gen_tcp.send(sock, line <> "\r\n")

  defp irc_register(sock, nick) do
    irc_send(sock, "NICK #{nick}")
    irc_send(sock, "USER #{nick} 0 * :#{nick}")
    irc_recv_until(sock, "422")
  end

  defp irc_recv_all(sock, acc \\ []) do
    case :gen_tcp.recv(sock, 0, 500) do
      {:ok, data} -> irc_recv_all(sock, [data | acc])
      {:error, _} -> acc |> Enum.reverse() |> Enum.join()
    end
  end

  defp irc_recv_until(sock, pattern, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_recv_until(sock, pattern, deadline, [])
  end

  defp do_recv_until(sock, pattern, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    case :gen_tcp.recv(sock, 0, min(remaining, 500)) do
      {:ok, data} ->
        acc = [data | acc]
        joined = acc |> Enum.reverse() |> Enum.join()
        if String.contains?(joined, pattern), do: joined, else: do_recv_until(sock, pattern, deadline, acc)
      {:error, _} ->
        if remaining <= 0, do: acc |> Enum.reverse() |> Enum.join(), else: do_recv_until(sock, pattern, deadline, acc)
    end
  end
end
