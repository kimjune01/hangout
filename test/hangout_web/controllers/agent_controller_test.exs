defmodule HangoutWeb.AgentControllerTest do
  use HangoutWeb.ConnCase, async: false

  alias Hangout.{AgentToken, ChannelServer, Participant, RateLimiter}

  setup do
    AgentToken.reset!()
    room = "agent-controller-#{System.unique_integer([:positive])}"
    channel = "#" <> room
    owner = "owner#{System.unique_integer([:positive])}"
    owner_pid = spawn(fn -> Process.sleep(:infinity) end)
    other_pid = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, _snapshot, mod_token} = ChannelServer.join(channel, participant(owner, owner_pid))
    {:ok, _snapshot, _token} = ChannelServer.join(channel, participant("alice", other_pid))
    {:ok, token} = AgentToken.create(channel, owner, "fp")
    flush_messages()

    on_exit(fn ->
      if Process.alive?(owner_pid), do: Process.exit(owner_pid, :kill)
      if Process.alive?(other_pid), do: Process.exit(other_pid, :kill)
    end)

    {:ok, room: room, channel: channel, owner: owner, token: token, mod_token: mod_token}
  end

  test "GET events sends context, history, and system events", %{
    room: room,
    channel: channel,
    owner: owner,
    token: token,
    mod_token: mod_token
  } do
    parent = self()

    pid =
      spawn(fn ->
        conn = get(build_conn(), "/#{room}/agent/#{token}/events")
        send(parent, {:sse_done, conn})
      end)

    Process.sleep(100)
    :ok = ChannelServer.end_room(channel, owner, mod_token)

    assert_receive {:sse_done, conn}, 2000

    body = response(conn, 200)
    assert body =~ "event: context\n"
    assert body =~ "\"owner\":\"#{owner}\""
    assert body =~ "event: history\n"
  end

  test "POST messages publishes as owner robot", %{
    room: room,
    channel: channel,
    owner: owner,
    token: token
  } do
    Phoenix.PubSub.subscribe(Hangout.PubSub, ChannelServer.topic_name(channel))
    flush_messages()

    conn =
      json_post("/#{room}/agent/#{token}/messages", %{
        "body" => "hello from agent",
        "client_msg_id" => "m1"
      })

    body = json_response(conn, 200)

    assert body["ok"] == true
    assert is_integer(body["message_id"])
    assert is_binary(body["at"])

    assert_receive {:hangout_event, {:message, ^channel, msg}}, 500
    assert msg.from == owner
    assert msg.agent == true
    assert msg.body == "hello from agent"
  end

  test "POST messages deduplicates client_msg_id", %{room: room, token: token} do
    assert %{"ok" => true} =
             "/#{room}/agent/#{token}/messages"
             |> json_post(%{"body" => "first", "client_msg_id" => "same"})
             |> json_response(200)

    assert %{"ok" => false, "error" => "duplicate"} =
             "/#{room}/agent/#{token}/messages"
             |> json_post(%{"body" => "second", "client_msg_id" => "same"})
             |> json_response(409)
  end

  test "POST drafts broadcasts to owner draft topic", %{
    room: room,
    channel: channel,
    owner: owner,
    token: token
  } do
    Phoenix.PubSub.subscribe(Hangout.PubSub, "agent_draft:#{channel}:#{owner}")

    conn = json_post("/#{room}/agent/#{token}/drafts", %{"body" => "draft me"})
    assert %{"ok" => true} = json_response(conn, 200)

    assert_receive {:agent_draft, %{body: "draft me", from: ^owner}}, 500
  end

  test "POST messages rate limits after six per minute", %{room: room, token: token} do
    for i <- 1..6 do
      conn =
        json_post("/#{room}/agent/#{token}/messages", %{
          "body" => "msg #{i}",
          "client_msg_id" => "rl-#{i}"
        })

      assert %{"ok" => true} = json_response(conn, 200)
    end

    conn =
      json_post("/#{room}/agent/#{token}/messages", %{
        "body" => "msg 7",
        "client_msg_id" => "rl-7"
      })

    assert %{"ok" => false, "error" => "rate_limited"} = json_response(conn, 429)
  end

  defp json_post(path, params) do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(params))
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
