defmodule Hangout.ChannelServerTest do
  use ExUnit.Case, async: false

  alias Hangout.{ChannelServer, ChannelRegistry, NickRegistry, Participant, Message}

  setup do
    # Clean up any leftover channels/nicks between tests
    on_exit(fn ->
      # Channels self-terminate; nicks need manual cleanup
      :ok
    end)

    :ok
  end

  defp make_participant(nick, opts \\ []) do
    transport = Keyword.get(opts, :transport, :irc)
    bot? = Keyword.get(opts, :bot?, false)
    pid = Keyword.get(opts, :pid, self())

    %Participant{
      nick: nick,
      user: nick,
      realname: nick,
      public_key: Keyword.get(opts, :public_key),
      transport: transport,
      pid: pid,
      joined_at: DateTime.utc_now(),
      last_seen_at: DateTime.utc_now(),
      bot?: bot?,
      modes: MapSet.new(),
      rate_limit_state: Hangout.RateLimiter.new()
    }
  end

  # AC1: A user can visit /calc-study, choose a nick, and join.
  # AC2: A second browser can visit the same URL and join the same room.
  # (Tested here at the ChannelServer level — LiveView tested separately)
  test "AC1+2: two participants can join the same room" do
    alice = make_participant("alice", pid: spawn(fn -> Process.sleep(:infinity) end))
    bob = make_participant("bob", pid: spawn(fn -> Process.sleep(:infinity) end))

    {:ok, snapshot_a, token} = ChannelServer.join("#test-ac12-mem", alice)
    assert snapshot_a.name == "#test-ac12-mem"
    assert is_binary(token)  # first joiner gets mod token
    assert length(snapshot_a.members) == 1

    {:ok, snapshot_b, nil_token} = ChannelServer.join("#test-ac12-mem", bob)
    assert nil_token == nil  # second joiner gets no token
    assert length(snapshot_b.members) == 2
  end

  # AC3: Messages sent from either browser appear in both browsers.
  test "AC3: messages broadcast to all participants via PubSub" do
    Phoenix.PubSub.subscribe(Hangout.PubSub, "channel:#test-ac3")

    alice = make_participant("alice-ac3", pid: spawn(fn -> Process.sleep(:infinity) end))
    bob = make_participant("bob-ac3", pid: spawn(fn -> Process.sleep(:infinity) end))

    {:ok, _, _} = ChannelServer.join("#test-ac3", alice)
    {:ok, _, _} = ChannelServer.join("#test-ac3", bob)

    # Drain join events
    flush_messages()

    {:ok, msg} = ChannelServer.message("#test-ac3", "alice-ac3", :privmsg, "hello")
    assert msg.body == "hello"
    assert msg.from == "alice-ac3"
    assert msg.kind == :privmsg

    # PubSub should deliver the message
    assert_receive {:hangout_event, {:message, "#test-ac3", ^msg}}, 1000
  end

  # AC4: A raw IRC client can connect, join #calc-study, and exchange messages with browser users.
  # (Tested via integration test — IRC module handles this)

  # AC5: A bot that speaks IRC can join as a normal nick and send/receive PRIVMSG.
  test "AC5: bot can join and send messages" do
    human = make_participant("human-ac5", pid: spawn(fn -> Process.sleep(:infinity) end))
    bot = make_participant("bot-ac5", pid: spawn(fn -> Process.sleep(:infinity) end), bot?: true)

    {:ok, _, _} = ChannelServer.join("#test-ac5", human)
    {:ok, snapshot, _} = ChannelServer.join("#test-ac5", bot)
    assert length(snapshot.members) == 2

    {:ok, msg} = ChannelServer.message("#test-ac5", "bot-ac5", :privmsg, "beep boop")
    assert msg.from == "bot-ac5"
  end

  # AC6: Nick changes, joins, parts, quits, topics, and kicks behave per IRC.
  test "AC6: nick change broadcasts to room" do
    Phoenix.PubSub.subscribe(Hangout.PubSub, "channel:#test-ac6")

    p = make_participant("oldnick", pid: spawn(fn -> Process.sleep(:infinity) end))
    {:ok, _, _} = ChannelServer.join("#test-ac6", p)
    flush_messages()

    :ok = ChannelServer.change_nick("#test-ac6", "oldnick", "newnick")
    assert_receive {:hangout_event, {:nick_changed, "#test-ac6", "oldnick", "newnick"}}, 1000
  end

  test "AC6: topic set by operator and by token" do
    creator = make_participant("topicuser", pid: spawn(fn -> Process.sleep(:infinity) end))
    other = make_participant("other-topic", pid: spawn(fn -> Process.sleep(:infinity) end))
    {:ok, _, token} = ChannelServer.join("#test-ac6t", creator)
    {:ok, _, _} = ChannelServer.join("#test-ac6t", other)

    # Operator can set topic (first joiner is op)
    :ok = ChannelServer.set_topic("#test-ac6t", "topicuser", "Hello World")
    {:ok, topic} = ChannelServer.topic("#test-ac6t")
    assert topic == "Hello World"

    # Non-op can set topic when +t is off (default: +t on, but op can set anyway)
    # Test token auth: non-op with token
    :ok = ChannelServer.set_topic("#test-ac6t", "other-topic", "Token Topic", token)
    {:ok, topic} = ChannelServer.topic("#test-ac6t")
    assert topic == "Token Topic"

    # Non-op without token can't set when +t is on
    {:error, :chanop_needed} = ChannelServer.set_topic("#test-ac6t", "other-topic", "Nope")
  end

  # AC7: The first human creator can kick, lock, unlock, and end the room using a capability URL.
  test "AC7: moderation via capability token" do
    Phoenix.PubSub.subscribe(Hangout.PubSub, "channel:#test-ac7")

    creator = make_participant("creator-ac7", pid: spawn(fn -> Process.sleep(:infinity) end))
    victim = make_participant("victim-ac7", pid: spawn(fn -> Process.sleep(:infinity) end))

    {:ok, _, token} = ChannelServer.join("#test-ac7", creator)
    {:ok, _, _} = ChannelServer.join("#test-ac7", victim)
    flush_messages()

    # Kick using token
    :ok = ChannelServer.kick("#test-ac7", "creator-ac7", "victim-ac7", "bye", token)
    assert_receive {:hangout_event, {:user_kicked, "#test-ac7", "creator-ac7", _, "bye"}}, 1000

    # Lock room
    :ok = ChannelServer.mode("#test-ac7", "creator-ac7", "+", :i, nil, token)
    {:ok, snapshot} = ChannelServer.snapshot("#test-ac7")
    assert snapshot.modes[:i] == true

    # Unlock room
    :ok = ChannelServer.mode("#test-ac7", "creator-ac7", "-", :i, nil, token)
    {:ok, snapshot} = ChannelServer.snapshot("#test-ac7")
    assert snapshot.modes[:i] == false
  end

  test "AC7: moderation fails without token" do
    creator = make_participant("c-ac7b", pid: spawn(fn -> Process.sleep(:infinity) end))
    other = make_participant("o-ac7b", pid: spawn(fn -> Process.sleep(:infinity) end))

    {:ok, _, _token} = ChannelServer.join("#test-ac7b", creator)
    {:ok, _, _} = ChannelServer.join("#test-ac7b", other)

    # Kick without token (and not op) should fail
    {:error, :chanop_needed} = ChannelServer.kick("#test-ac7b", "o-ac7b", "c-ac7b", "nope")
  end

  # AC8: When the last human leaves, the room process terminates and its buffer is discarded.
  test "AC8: room dies when last human leaves" do
    p = make_participant("lonely", pid: spawn(fn -> Process.sleep(:infinity) end))
    {:ok, _, _} = ChannelServer.join("#test-ac8", p)

    # Room should be alive
    assert ChannelRegistry.exists?("#test-ac8")

    # Part — last human leaves
    :ok = ChannelServer.part("#test-ac8", "lonely", "goodbye")

    # Give GenServer time to terminate
    Process.sleep(100)

    # Room should be gone
    refute ChannelRegistry.exists?("#test-ac8")
  end

  # AC9: Bots alone do not keep the room alive.
  test "AC9: bot alone does not keep room alive" do
    human = make_participant("h-ac9", pid: spawn(fn -> Process.sleep(:infinity) end))
    bot = make_participant("b-ac9", pid: spawn(fn -> Process.sleep(:infinity) end), bot?: true)

    {:ok, _, _} = ChannelServer.join("#test-ac9", human)
    {:ok, _, _} = ChannelServer.join("#test-ac9", bot)

    assert ChannelRegistry.exists?("#test-ac9")

    # Human leaves — only bot remains
    :ok = ChannelServer.part("#test-ac9", "h-ac9", "bye")
    Process.sleep(100)

    # Room should die even though bot is still "in" it
    refute ChannelRegistry.exists?("#test-ac9")
  end

  # AC10: A room TTL, when set, destroys the room at expiry.
  test "AC10: TTL expires and room dies" do
    p = make_participant("ttl-user", pid: spawn(fn -> Process.sleep(:infinity) end))
    {:ok, _, token} = ChannelServer.join("#test-ac10", p)

    # Set a 1-second TTL
    :ok = ChannelServer.set_ttl("#test-ac10", "ttl-user", 1, token)

    assert ChannelRegistry.exists?("#test-ac10")

    # Wait for TTL to expire
    Process.sleep(1500)

    refute ChannelRegistry.exists?("#test-ac10")
  end

  # AC12: No message text is written to durable storage or logs.
  test "AC12: no Ecto, no database — messages are in-memory only" do
    refute Code.ensure_loaded?(Ecto)
    refute Code.ensure_loaded?(Ecto.Repo)

    channel = "#test-ac12-#{System.unique_integer([:positive])}"
    pid = spawn(fn -> Process.sleep(:infinity) end)
    p = make_participant("mem-user-#{System.unique_integer([:positive])}", pid: pid)
    {:ok, _, token} = ChannelServer.join(channel, p)
    assert is_binary(token)

    {:ok, _} = ChannelServer.message(channel, p.nick, :privmsg, "secret message")

    {:ok, snapshot} = ChannelServer.snapshot(channel)
    assert length(snapshot.buffer) == 1
    assert hd(snapshot.buffer).body == "secret message"

    :ok = ChannelServer.end_room(channel, p.nick, token)
    Process.sleep(200)

    refute ChannelRegistry.exists?(channel)
  end

  # AC13: Invalid or expired room states do not expose historical content.
  test "AC13: dead room returns error, not old data" do
    p = make_participant("ghost", pid: spawn(fn -> Process.sleep(:infinity) end))
    {:ok, _, _} = ChannelServer.join("#test-ac13", p)
    :ok = ChannelServer.part("#test-ac13", "ghost", "bye")
    Process.sleep(100)

    # Attempting to get data from dead room
    assert {:error, :no_such_channel} = ChannelServer.snapshot("#test-ac13")
    assert {:error, :no_such_channel} = ChannelServer.topic("#test-ac13")
  end

  # Buffer bounded at 100
  test "buffer is bounded at max_buffer_size" do
    # Use multiple participants to avoid rate limiting
    max = Application.get_env(:hangout, :max_buffer_size, 100)
    pids = for i <- 1..(max + 20), do: spawn(fn -> Process.sleep(:infinity) end)
    participants = Enum.with_index(pids, 1) |> Enum.map(fn {pid, i} ->
      make_participant("flood#{i}", pid: pid)
    end)

    # Join all
    for p <- participants do
      ChannelServer.join("#test-buffer", p)
    end

    # Each sends one message (no rate limit hit)
    for {p, i} <- Enum.with_index(participants, 1) do
      ChannelServer.message("#test-buffer", p.nick, :privmsg, "msg #{i}")
    end

    {:ok, snapshot} = ChannelServer.snapshot("#test-buffer")
    assert length(snapshot.buffer) == max
  end

  # Rate limiting
  test "rate limiting rejects excess messages" do
    p = make_participant("spammer", pid: spawn(fn -> Process.sleep(:infinity) end))
    {:ok, _, _} = ChannelServer.join("#test-rate", p)

    # Send burst + 1
    burst = Application.get_env(:hangout, :message_burst, 10)

    results =
      for _ <- 1..(burst + 5) do
        ChannelServer.message("#test-rate", "spammer", :privmsg, "spam")
      end

    ok_count = Enum.count(results, &match?({:ok, _}, &1))
    rate_limited = Enum.count(results, &match?({:error, :rate_limited}, &1))

    assert ok_count == burst
    assert rate_limited == 5
  end

  # Body limit
  test "body over 400 bytes is rejected" do
    p = make_participant("longmsg", pid: spawn(fn -> Process.sleep(:infinity) end))
    {:ok, _, _} = ChannelServer.join("#test-body", p)

    long_body = String.duplicate("x", 401)
    assert {:error, :body_too_long} = ChannelServer.message("#test-body", "longmsg", :privmsg, long_body)

    ok_body = String.duplicate("x", 400)
    assert {:ok, _} = ChannelServer.message("#test-body", "longmsg", :privmsg, ok_body)
  end

  # Invite-only (locked) channel
  test "locked channel rejects new joins" do
    creator = make_participant("locker", pid: spawn(fn -> Process.sleep(:infinity) end))
    outsider = make_participant("outsider", pid: spawn(fn -> Process.sleep(:infinity) end))

    {:ok, _, token} = ChannelServer.join("#test-lock", creator)

    # Lock the room
    :ok = ChannelServer.mode("#test-lock", "locker", "+", :i, nil, token)

    # New join should fail
    {:error, :invite_only} = ChannelServer.join("#test-lock", outsider)
  end

  # CLEAR command
  test "clear wipes buffer and broadcasts" do
    Phoenix.PubSub.subscribe(Hangout.PubSub, "channel:#test-clear")

    p = make_participant("clearer", pid: spawn(fn -> Process.sleep(:infinity) end))
    {:ok, _, token} = ChannelServer.join("#test-clear", p)
    flush_messages()

    {:ok, _} = ChannelServer.message("#test-clear", "clearer", :privmsg, "keep this? nope")
    flush_messages()

    :ok = ChannelServer.clear("#test-clear", "clearer", token)
    assert_receive {:hangout_event, {:buffer_cleared, "#test-clear", "clearer"}}, 1000

    {:ok, snapshot} = ChannelServer.snapshot("#test-clear")
    # Buffer should have only the notice about clearing
    assert Enum.all?(snapshot.buffer, fn m -> m.kind in [:system, :notice] end)
  end

  # END command
  test "end room destroys it immediately" do
    creator = make_participant("ender", pid: spawn(fn -> Process.sleep(:infinity) end))
    {:ok, _, token} = ChannelServer.join("#test-end", creator)

    :ok = ChannelServer.end_room("#test-end", "ender", token)
    Process.sleep(100)

    refute ChannelRegistry.exists?("#test-end")
  end

  # Nick registry
  test "nick uniqueness is enforced" do
    assert :ok = NickRegistry.register("unique1", %{transport: :irc})
    assert {:error, :nick_in_use} = NickRegistry.register("unique1", %{transport: :irc})
    NickRegistry.unregister("unique1")
  end

  # Bot cannot create room
  test "bot cannot be first to join" do
    bot = make_participant("lonely-bot", pid: spawn(fn -> Process.sleep(:infinity) end), bot?: true)
    assert {:error, :bot_needs_human} = ChannelServer.join("#test-botfirst", bot)
  end

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      100 -> :ok
    end
  end
end
