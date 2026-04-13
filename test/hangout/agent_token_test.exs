defmodule Hangout.AgentTokenTest do
  use ExUnit.Case, async: false

  alias Hangout.{AgentToken, ChannelServer, Participant, RateLimiter}

  setup do
    AgentToken.reset!()
    room = "#agent-token-#{System.unique_integer([:positive])}"
    owner = "owner#{System.unique_integer([:positive])}"
    pid = spawn(fn -> Process.sleep(:infinity) end)
    participant = participant(owner, pid)
    {:ok, _snapshot, mod_token} = ChannelServer.join(room, participant)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    {:ok, room: room, slug: String.trim_leading(room, "#"), owner: owner, mod_token: mod_token}
  end

  test "create returns opaque token and validate returns metadata", %{
    room: room,
    slug: slug,
    owner: owner
  } do
    assert "agt_" <> encoded = token = AgentToken.create(room, owner, "fp")
    assert byte_size(encoded) >= 43

    assert {:ok, metadata} = AgentToken.validate(slug, token)
    assert metadata.room_id == room
    assert metadata.owner_nick == owner
    assert metadata.keypair_fingerprint == "fp"
    assert %DateTime{} = metadata.created_at
    assert %DateTime{} = metadata.expires_at
  end

  test "revoke invalidates a token", %{room: room, slug: slug, owner: owner} do
    token = AgentToken.create(room, owner, "fp")
    assert :ok = AgentToken.revoke(token)
    assert {:error, :token_revoked} = AgentToken.validate(slug, token)
  end

  test "one active agent per nick per room", %{room: room, owner: owner} do
    token = AgentToken.create(room, owner, "fp")
    assert {:error, :active_token_exists} = AgentToken.create(room, owner, "fp2")

    :ok = AgentToken.revoke(token)
    assert "agt_" <> _replacement = AgentToken.create(room, owner, "fp2")
  end

  test "revoke_for_nick revokes active tokens for that nick", %{
    room: room,
    slug: slug,
    owner: owner
  } do
    token = AgentToken.create(room, owner, "fp")
    assert 1 = AgentToken.revoke_for_nick(room, owner)
    assert {:error, :token_revoked} = AgentToken.validate(slug, token)
  end

  test "tokens expire after configured ttl", %{room: room, slug: slug, owner: owner} do
    previous = Application.get_env(:hangout, :agent_token_ttl_seconds)
    Application.put_env(:hangout, :agent_token_ttl_seconds, 0)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:hangout, :agent_token_ttl_seconds)
      else
        Application.put_env(:hangout, :agent_token_ttl_seconds, previous)
      end
    end)

    token = AgentToken.create(room, owner, "fp")
    Process.sleep(10)
    assert {:error, :token_expired} = AgentToken.validate(slug, token)
  end

  test "validate fails when the room has ended", %{
    room: room,
    slug: slug,
    owner: owner,
    mod_token: mod_token
  } do
    token = AgentToken.create(room, owner, "fp")
    assert :ok = ChannelServer.end_room(room, owner, mod_token)
    Process.sleep(50)
    assert {:error, reason} = AgentToken.validate(slug, token)
    assert reason in [:invalid_token, :room_ended]
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
end
