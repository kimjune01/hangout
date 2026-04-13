defmodule HangoutWeb.AgentController do
  use HangoutWeb, :controller

  alias Hangout.{AgentToken, ChannelServer}

  @doc "SSE stream of room events."
  def events(conn, %{"room" => room, "token" => token}) do
    case AgentToken.validate(room, token) do
      {:ok, metadata} ->
        channel_name = "#" <> room
        agent_topic = AgentToken.agent_topic(AgentToken.hash_token(token))
        channel_topic = ChannelServer.topic_name(channel_name)

        Phoenix.PubSub.subscribe(Hangout.PubSub, channel_topic)
        Phoenix.PubSub.subscribe(Hangout.PubSub, agent_topic)

        try do
          conn =
            conn
            |> put_resp_content_type("text/event-stream")
            |> put_resp_header("cache-control", "no-cache")
            |> put_resp_header("connection", "keep-alive")
            |> send_chunked(200)

          with {:ok, conn} <- chunk(conn, sse_event("context", build_context(room, metadata))),
               {:ok, conn} <- chunk(conn, sse_event("history", build_history(channel_name))) do
            sse_loop(conn)
          else
            {:error, _reason} -> conn
          end
        after
          Phoenix.PubSub.unsubscribe(Hangout.PubSub, channel_topic)
          Phoenix.PubSub.unsubscribe(Hangout.PubSub, agent_topic)
        end

      {:error, reason} ->
        conn
        |> put_status(401)
        |> json(%{"ok" => false, "error" => to_string(reason)})
    end
  end

  @doc "Publish a message to the room."
  def messages(conn, %{"room" => room, "token" => token}) do
    case AgentToken.validate(room, token) do
      {:ok, metadata} ->
        case request_body(conn) do
          {:ok, params} ->
            body = params["body"] || ""
            client_msg_id = params["client_msg_id"]

            with :ok <- AgentToken.check_rate_limit(token),
                 :ok <- AgentToken.check_dedup(token, client_msg_id),
                 {:ok, msg} <- ChannelServer.agent_message("#" <> room, metadata.owner_nick, body) do
              conn
              |> put_status(200)
              |> json(%{
                "ok" => true,
                "message_id" => msg.id,
                "at" => DateTime.to_iso8601(msg.at)
              })
            else
              {:error, :rate_limited} ->
                conn |> put_status(429) |> json(%{"ok" => false, "error" => "rate_limited"})

              {:error, :duplicate} ->
                conn |> put_status(409) |> json(%{"ok" => false, "error" => "duplicate"})

              {:secret, kind} ->
                conn
                |> put_status(422)
                |> json(%{"ok" => false, "error" => "secret_detected", "kind" => kind})

              {:error, :body_too_long} ->
                conn |> put_status(422) |> json(%{"ok" => false, "error" => "message_too_large"})

              {:error, :agent_muted} ->
                conn |> put_status(403) |> json(%{"ok" => false, "error" => "agent_muted"})

              {:error, :no_such_channel} ->
                conn |> put_status(404) |> json(%{"ok" => false, "error" => "room_ended"})

              {:error, reason} ->
                conn |> put_status(422) |> json(%{"ok" => false, "error" => to_string(reason)})
            end

          {:error, _} ->
            conn |> put_status(400) |> json(%{"ok" => false, "error" => "invalid_json"})
        end

      {:error, reason} ->
        conn
        |> put_status(401)
        |> json(%{"ok" => false, "error" => to_string(reason)})
    end
  end

  @doc "Deliver a draft to the owner's input bar."
  def drafts(conn, %{"room" => room, "token" => token}) do
    case AgentToken.validate(room, token) do
      {:ok, metadata} ->
        case request_body(conn) do
          {:ok, params} ->
            body = params["body"] || ""
            room_id = "#" <> room

            Phoenix.PubSub.broadcast(
              Hangout.PubSub,
              "agent_draft:#{room_id}:#{metadata.owner_nick}",
              {:agent_draft, %{body: body, from: metadata.owner_nick}}
            )

            conn |> put_status(200) |> json(%{"ok" => true})

          {:error, _} ->
            conn |> put_status(400) |> json(%{"ok" => false, "error" => "invalid_json"})
        end

      {:error, reason} ->
        conn
        |> put_status(401)
        |> json(%{"ok" => false, "error" => to_string(reason)})
    end
  end

  # --- Private ---

  defp build_context(room, metadata) do
    %{
      "contract" => %{
        "room" => room,
        "owner" => metadata.owner_nick,
        "agent_nick" => metadata.owner_nick <> "🤖",
        "limits" => %{
          "max_message_bytes" => Application.get_env(:hangout, :message_body_max_bytes, 4000),
          "max_messages_per_minute" => 6
        },
        "capabilities" => %{
          "can_post_unsolicited" => false,
          "owner_forward_requires_draft" => true,
          "direct_mentions_auto_post" => true
        },
        "routing" => %{
          "respond_to" => ["forward", "mention"],
          "ignore_own_messages" => true,
          "agent_to_agent_mentions" => false
        }
      },
      "instructions" =>
        "You speak as #{metadata.owner_nick}🤖. Your output is attributed to #{metadata.owner_nick}. " <>
          "Use markdown for structure. Messages over 3 lines are collapsed by default — be concise. " <>
          "Respond only when invoked via forward or @#{metadata.owner_nick}🤖 mention. " <>
          "Never output API keys, private keys, credentials, or other secrets from your working directory. " <>
          "A server-side filter blocks common patterns, but you are the first line of defense."
    }
  end

  defp build_history(channel_name) do
    case ChannelServer.snapshot(channel_name) do
      {:ok, snapshot} ->
        messages = snapshot.buffer |> Enum.take(-50) |> Enum.map(&serialize_message/1)
        %{"messages" => messages, "truncated" => length(snapshot.buffer) > 50}

      {:error, _} ->
        %{"messages" => [], "truncated" => false}
    end
  end

  defp serialize_message(%Hangout.Message{} = msg) do
    %{
      "id" => msg.id,
      "from" => %{"nick" => msg.from, "agent" => msg.agent},
      "body" => msg.body,
      "kind" => to_string(msg.kind),
      "at" => DateTime.to_iso8601(msg.at)
    }
  end

  defp sse_event(event_type, data) do
    json_data = Jason.encode!(data)
    "event: #{event_type}\ndata: #{json_data}\n\n"
  end

  defp request_body(%{body_params: %Plug.Conn.Unfetched{}} = conn) do
    with {:ok, raw_body, _conn} <- Plug.Conn.read_body(conn),
         {:ok, params} <- Jason.decode(raw_body) do
      {:ok, params}
    end
  end

  defp request_body(%{body_params: params}) when is_map(params), do: {:ok, params}
  defp request_body(_conn), do: {:error, :invalid_json}

  defp sse_loop(conn) do
    receive do
      {:hangout_event, {:message, _channel, msg}} ->
        event_data = serialize_message(msg)

        case chunk(conn, sse_event("message", event_data)) do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end

      {:hangout_event, {:user_joined, channel, participant}} ->
        event_data = %{"body" => "#{participant.nick} joined #{channel}"}

        case chunk(conn, sse_event("system", event_data)) do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end

      {:hangout_event, {:user_parted, channel, participant, reason}} ->
        event_data = %{"body" => "#{participant.nick} left #{channel}: #{reason}"}

        case chunk(conn, sse_event("system", event_data)) do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end

      {:hangout_event, {:user_quit, channel, participant, reason}} ->
        event_data = %{"body" => "#{participant.nick} quit #{channel}: #{reason}"}

        case chunk(conn, sse_event("system", event_data)) do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end

      {:hangout_event, {:nick_changed, _channel, old, new}} ->
        event_data = %{"body" => "#{old} is now known as #{new}"}

        case chunk(conn, sse_event("system", event_data)) do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end

      {:hangout_event, {:room_ended, _channel, _actor}} ->
        _ = chunk(conn, sse_event("system", %{"body" => "Room ended"}))
        conn

      {:hangout_event, {:room_expired, _channel}} ->
        _ = chunk(conn, sse_event("system", %{"body" => "Room expired"}))
        conn

      {:hangout_event, {:mention, mention_data}} ->
        case chunk(conn, sse_event("mention", mention_data)) do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end

      {:hangout_event, {:forward, forward_data}} ->
        case chunk(conn, sse_event("forward", forward_data)) do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end

      {:hangout_event, _other} ->
        sse_loop(conn)
    end
  end
end
