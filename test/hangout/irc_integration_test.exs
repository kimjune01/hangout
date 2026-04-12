defmodule Hangout.IRCIntegrationTest do
  use ExUnit.Case, async: false

  @port Application.compile_env(:hangout, :irc_port, 16667)

  defp connect do
    {:ok, sock} = :gen_tcp.connect(~c"localhost", @port, [:binary, active: false, packet: :line])
    sock
  end

  defp send_irc(sock, line) do
    :gen_tcp.send(sock, line <> "\r\n")
  end

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

      {:error, :timeout} ->
        if remaining <= 0, do: acc |> Enum.reverse() |> Enum.join(), else: do_recv_until(sock, pattern, deadline, acc)
    end
  end

  defp register(sock, nick) do
    send_irc(sock, "NICK #{nick}")
    send_irc(sock, "USER #{nick} 0 * :#{nick}")
    recv_until(sock, "422")
  end

  # AC4: A raw IRC client can connect, join, and exchange messages with others
  test "AC4: full IRC registration and welcome burst" do
    sock = connect()
    output = register(sock, "irc-test1")

    assert output =~ "001"
    assert output =~ "Welcome to hangout"
    assert output =~ "005"
    assert output =~ "422"

    :gen_tcp.close(sock)
  end

  test "AC4: two IRC clients exchange messages in same room" do
    alice = connect()
    bob = connect()

    register(alice, "alice-irc")
    register(bob, "bob-irc")

    # Alice creates room
    send_irc(alice, "JOIN #irc-test")
    alice_join = recv_until(alice, "366")
    assert alice_join =~ "JOIN #irc-test"
    assert alice_join =~ "366"  # end of NAMES

    # Bob joins same room
    send_irc(bob, "JOIN #irc-test")
    bob_join = recv_until(bob, "366")
    assert bob_join =~ "JOIN #irc-test"

    # Alice should see bob join
    Process.sleep(200)
    alice_sees_bob = recv_all(alice)
    assert alice_sees_bob =~ "bob-irc"
    assert alice_sees_bob =~ "JOIN"

    # Alice sends message
    send_irc(alice, "PRIVMSG #irc-test :hello bob!")
    bob_msg = recv_until(bob, "hello bob!")
    assert bob_msg =~ "PRIVMSG #irc-test :hello bob!"

    # Bob sends message
    send_irc(bob, "PRIVMSG #irc-test :hi alice!")
    alice_msg = recv_until(alice, "hi alice!")
    assert alice_msg =~ "PRIVMSG #irc-test :hi alice!"

    :gen_tcp.close(alice)
    :gen_tcp.close(bob)
  end

  # AC6: Nick changes work over IRC
  test "AC6: nick change over IRC" do
    sock = connect()
    register(sock, "oldname-irc")

    send_irc(sock, "JOIN #nick-test")
    recv_until(sock, "366")

    send_irc(sock, "NICK newname-irc")
    Process.sleep(200)
    output = recv_all(sock)
    # Server should confirm the nick change
    assert output =~ "NICK" or output =~ "newname-irc"

    :gen_tcp.close(sock)
  end

  # AC5: Bot marks itself with BOT command
  test "AC5: BOT command marks connection" do
    human = connect()
    bot = connect()

    register(human, "human-bot-test")
    register(bot, "bot-bot-test")

    # Human creates room first
    send_irc(human, "JOIN #bot-test")
    recv_until(human, "366")

    # Bot joins
    send_irc(bot, "BOT")
    Process.sleep(200)
    bot_notice = recv_all(bot)
    assert bot_notice =~ "bot"

    send_irc(bot, "JOIN #bot-test")
    recv_until(bot, "366")

    # Human leaves — room should die because bot alone doesn't keep it alive
    send_irc(human, "PART #bot-test :bye")
    Process.sleep(300)

    # Bot should receive termination notice
    bot_end = recv_all(bot)
    assert bot_end =~ "PART" or bot_end =~ "NOTICE" or bot_end =~ "Room"

    :gen_tcp.close(human)
    :gen_tcp.close(bot)
  end

  # AC7: MODAUTH + moderation over IRC
  test "AC7: moderation via MODAUTH" do
    creator = connect()
    victim = connect()

    register(creator, "mod-creator")
    register(victim, "mod-victim")

    # Creator joins and gets token
    send_irc(creator, "JOIN #mod-test")
    join_output = recv_until(creator, "token")
    token = Regex.run(~r/token: ([a-f0-9]+)/, join_output) |> List.last()

    # Victim joins
    send_irc(victim, "JOIN #mod-test")
    recv_until(victim, "366")
    Process.sleep(200)
    recv_all(creator)  # drain

    # Creator authenticates as mod
    send_irc(creator, "MODAUTH #{token}")
    Process.sleep(200)
    mod_result = recv_all(creator)
    assert mod_result =~ "Moderator authentication successful"

    # Kick victim
    send_irc(creator, "KICK #mod-test mod-victim :begone")
    Process.sleep(200)
    victim_kicked = recv_all(victim)
    assert victim_kicked =~ "KICK"

    :gen_tcp.close(creator)
    :gen_tcp.close(victim)
  end

  # AC8+AC9 tested in channel_server_test
  # AC10 tested in channel_server_test
  # AC11 (notifications) is browser-only

  # LIST returns empty
  test "LIST returns empty by policy" do
    sock = connect()
    register(sock, "list-test")

    send_irc(sock, "LIST")
    Process.sleep(200)
    output = recv_all(sock)
    assert output =~ "323"  # RPL_LISTEND

    :gen_tcp.close(sock)
  end

  # QUIT cleanly disconnects
  test "QUIT sends closing message" do
    sock = connect()
    register(sock, "quit-test")

    send_irc(sock, "JOIN #quit-room")
    recv_until(sock, "366")

    send_irc(sock, "QUIT :goodbye")
    Process.sleep(200)
    output = recv_all(sock)
    assert output =~ "Closing Link" or output =~ "ERROR"

    :gen_tcp.close(sock)
  end
end
