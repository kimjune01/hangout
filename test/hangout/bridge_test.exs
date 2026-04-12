defmodule Hangout.BridgeTest do
  @moduledoc """
  Tests the bridge between ChannelServer events and IRC wire format.
  Verifies that PubSub events have the expected shape and that
  IRC connection handlers produce correct wire output.
  """
  use ExUnit.Case, async: false

  alias Hangout.{ChannelServer, Participant}
  alias Hangout.IRC.Parser

  @port Application.compile_env(:hangout, :irc_port, 16667)

  defp make_participant(nick, opts \\ []) do
    %Participant{
      nick: nick,
      user: nick,
      realname: nick,
      public_key: Keyword.get(opts, :public_key),
      transport: Keyword.get(opts, :transport, :irc),
      pid: Keyword.get(opts, :pid, self()),
      joined_at: DateTime.utc_now(),
      last_seen_at: DateTime.utc_now(),
      bot?: Keyword.get(opts, :bot?, false),
      modes: MapSet.new(),
      rate_limit_state: Hangout.RateLimiter.new()
    }
  end

  defp connect do
    {:ok, sock} = :gen_tcp.connect(~c"localhost", @port, [:binary, active: false, packet: :line])
    sock
  end

  defp send_irc(sock, line), do: :gen_tcp.send(sock, line <> "\r\n")

  defp recv_all(sock, acc \\ []) do
    case :gen_tcp.recv(sock, 0, 500) do
      {:ok, data} -> recv_all(sock, [data | acc])
      {:error, :timeout} -> acc |> Enum.reverse() |> Enum.join()
      {:error, :closed} -> acc |> Enum.reverse() |> Enum.join()
    end
  end

  defp recv_until(sock, pattern, timeout \\ 2000) do
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

  defp register(sock, nick) do
    send_irc(sock, "NICK #{nick}")
    send_irc(sock, "USER #{nick} 0 * :#{nick}")
    recv_until(sock, "422")
  end

  # --- PubSub event shape tests ---

  describe "ChannelServer → PubSub event shapes" do
    test "message event has expected structure" do
      channel = "#bridge-msg-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Hangout.PubSub, "channel:#{channel}")

      p = make_participant("bridge-user", pid: spawn(fn -> Process.sleep(:infinity) end))
      {:ok, _, _} = ChannelServer.join(channel, p)
      flush()

      {:ok, _msg} = ChannelServer.message(channel, "bridge-user", :privmsg, "hello")

      assert_receive {:hangout_event, {:message, ^channel, msg}}, 1000
      assert msg.from == "bridge-user"
      assert msg.body == "hello"
      assert msg.kind == :privmsg
      assert msg.target == channel
      assert is_integer(msg.id)
      assert %DateTime{} = msg.at
    end

    test "user_joined event has participant map" do
      channel = "#bridge-join-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Hangout.PubSub, "channel:#{channel}")

      p1 = make_participant("first-joiner", pid: spawn(fn -> Process.sleep(:infinity) end))
      {:ok, _, _} = ChannelServer.join(channel, p1)
      flush()

      p2 = make_participant("second-joiner", pid: spawn(fn -> Process.sleep(:infinity) end))
      {:ok, _, _} = ChannelServer.join(channel, p2)

      assert_receive {:hangout_event, {:user_joined, ^channel, participant}}, 1000
      assert participant.nick == "second-joiner"
      assert is_map(participant)
    end

    test "user_parted event includes reason" do
      channel = "#bridge-part-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Hangout.PubSub, "channel:#{channel}")

      p1 = make_participant("parter1", pid: spawn(fn -> Process.sleep(:infinity) end))
      p2 = make_participant("parter2", pid: spawn(fn -> Process.sleep(:infinity) end))
      {:ok, _, _} = ChannelServer.join(channel, p1)
      {:ok, _, _} = ChannelServer.join(channel, p2)
      flush()

      :ok = ChannelServer.part(channel, "parter2", "goodbye")

      assert_receive {:hangout_event, {:user_parted, ^channel, participant, "goodbye"}}, 1000
      assert participant.nick == "parter2"
    end

    test "nick_changed event has old and new nick" do
      channel = "#bridge-nick-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Hangout.PubSub, "channel:#{channel}")

      p = make_participant("oldname", pid: spawn(fn -> Process.sleep(:infinity) end))
      {:ok, _, _} = ChannelServer.join(channel, p)
      flush()

      :ok = ChannelServer.change_nick(channel, "oldname", "newname")

      assert_receive {:hangout_event, {:nick_changed, ^channel, "oldname", "newname"}}, 1000
    end

    test "user_quit event on process death" do
      channel = "#bridge-quit-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Hangout.PubSub, "channel:#{channel}")

      keeper = make_participant("keeper", pid: spawn(fn -> Process.sleep(:infinity) end))
      {:ok, _, _} = ChannelServer.join(channel, keeper)
      flush()

      doomed_pid = spawn(fn -> Process.sleep(:infinity) end)
      doomed = make_participant("doomed", pid: doomed_pid)
      {:ok, _, _} = ChannelServer.join(channel, doomed)
      flush()

      Process.exit(doomed_pid, :kill)

      assert_receive {:hangout_event, {:user_quit, ^channel, participant, "Connection lost"}}, 1000
      assert participant.nick == "doomed"
    end
  end

  # --- IRC wire format from PubSub events ---

  describe "PubSub event → IRC wire output" do
    test "message from another user arrives as PRIVMSG" do
      sock = connect()
      register(sock, "wire-recv")

      send_irc(sock, "JOIN #wire-test")
      recv_until(sock, "366")

      # Another participant sends a message via ChannelServer
      other = make_participant("other-user", pid: spawn(fn -> Process.sleep(:infinity) end))
      {:ok, _, _} = ChannelServer.join("#wire-test", other)
      Process.sleep(200)
      recv_all(sock)  # drain join event

      {:ok, _} = ChannelServer.message("#wire-test", "other-user", :privmsg, "hello from the other side")
      output = recv_until(sock, "hello from the other side")

      assert output =~ "PRIVMSG #wire-test :hello from the other side"
      assert output =~ "other-user"

      :gen_tcp.close(sock)
    end

    test "nick change from another user arrives as NICK" do
      sock = connect()
      register(sock, "wire-nick")

      send_irc(sock, "JOIN #wire-nick-test")
      recv_until(sock, "366")

      other = make_participant("changer", pid: spawn(fn -> Process.sleep(:infinity) end))
      {:ok, _, _} = ChannelServer.join("#wire-nick-test", other)
      Process.sleep(200)
      recv_all(sock)

      :ok = ChannelServer.change_nick("#wire-nick-test", "changer", "newchanger")
      output = recv_until(sock, "newchanger")

      assert output =~ "NICK"
      assert output =~ "newchanger"

      :gen_tcp.close(sock)
    end

    test "topic change arrives as TOPIC" do
      sock = connect()
      register(sock, "wire-topic")

      send_irc(sock, "JOIN #wire-topic-test")
      recv_until(sock, "366")
      recv_all(sock)

      :ok = ChannelServer.set_topic("#wire-topic-test", "wire-topic", "New Topic")
      output = recv_until(sock, "New Topic")

      assert output =~ "TOPIC"
      assert output =~ "New Topic"

      :gen_tcp.close(sock)
    end
  end

  defp flush do
    receive do
      _ -> flush()
    after
      100 -> :ok
    end
  end
end
