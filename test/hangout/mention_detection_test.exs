defmodule Hangout.MentionDetectionTest do
  use ExUnit.Case, async: false

  alias Hangout.{AgentToken, ChannelServer, Participant, RateLimiter}

  setup do
    AgentToken.reset!()
    room = "#mention-#{System.unique_integer([:positive])}"
    owner_pid = spawn(fn -> Process.sleep(:infinity) end)
    sender_pid = spawn(fn -> Process.sleep(:infinity) end)
    owner = participant("June", owner_pid)
    sender = participant("alice", sender_pid)

    {:ok, _snapshot, _token} = ChannelServer.join(room, owner)
    {:ok, _snapshot, _token} = ChannelServer.join(room, sender)
    {:ok, agent_token} = AgentToken.create(room, owner.nick, "fp")

    Phoenix.PubSub.subscribe(
      Hangout.PubSub,
      AgentToken.agent_topic(AgentToken.hash_token(agent_token))
    )

    flush_messages()

    on_exit(fn ->
      if Process.alive?(owner_pid), do: Process.exit(owner_pid, :kill)
      if Process.alive?(sender_pid), do: Process.exit(sender_pid, :kill)
    end)

    {:ok, room: room}
  end

  test "routes exact robot-suffixed mentions case-insensitively", %{room: room} do
    {:ok, msg} = ChannelServer.message(room, "alice", :privmsg, "@june🤖 what do you think?")

    assert_receive {:hangout_event,
                    {:mention,
                     %{
                       "id" => id,
                       "from" => %{"nick" => "alice", "agent" => false},
                       "body" => "@june🤖 what do you think?"
                     }}},
                   500

    assert id == msg.id
  end

  test "does not route mentions without exact robot suffix", %{room: room} do
    {:ok, _msg} = ChannelServer.message(room, "alice", :privmsg, "@june what do you think?")
    refute_receive {:hangout_event, {:mention, _}}, 100
  end

  test "ignores mentions inside backtick code spans", %{room: room} do
    {:ok, _msg} = ChannelServer.message(room, "alice", :privmsg, "try `@june🤖 help` here")
    refute_receive {:hangout_event, {:mention, _}}, 100
  end

  test "skips agent-to-agent mentions", %{room: room} do
    {:ok, _msg} = ChannelServer.agent_message(room, "alice", "@june🤖 ping")
    refute_receive {:hangout_event, {:mention, _}}, 100
  end

  defp participant(nick, pid) do
    %Participant{
      nick: nick,
      user: nick,
      realname: nick,
      transport: :irc,
      pid: pid,
      joined_at: DateTime.utc_now(),
      last_seen_at: DateTime.utc_now(),
      modes: MapSet.new(),
      rate_limit_state: RateLimiter.new()
    }
  end

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      20 -> :ok
    end
  end
end
