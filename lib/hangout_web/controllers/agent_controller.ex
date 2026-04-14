defmodule HangoutWeb.AgentController do
  use HangoutWeb, :controller

  alias Hangout.{AgentToken, ChannelServer}

  @doc "SSE stream of room events."
  def events(conn, %{"room" => room, "token" => token}) do
    case AgentToken.validate(room, token) do
      {:ok, metadata} ->
        channel_name = "#" <> room
        token_hash = AgentToken.hash_token(token)
        agent_topic = AgentToken.agent_topic(token_hash)
        channel_topic = ChannelServer.topic_name(channel_name)
        presence_topic = AgentToken.presence_topic(channel_name, metadata.owner_nick)

        Phoenix.PubSub.subscribe(Hangout.PubSub, channel_topic)
        Phoenix.PubSub.subscribe(Hangout.PubSub, agent_topic)
        AgentToken.mark_attached(token_hash, self(), presence_topic)

        try do
          conn =
            conn
            |> put_resp_content_type("text/event-stream")
            |> put_resp_header("cache-control", "no-cache")
            |> put_resp_header("connection", "keep-alive")
            |> send_chunked(200)

          # Schedule expiry timer
          ttl_ms = DateTime.diff(metadata.expires_at, DateTime.utc_now(), :millisecond)
          if ttl_ms > 0, do: Process.send_after(self(), :token_expired, ttl_ms)

          with {:ok, conn} <- chunk(conn, sse_event("context", build_context(room, token, metadata))),
               {:ok, conn} <- chunk(conn, sse_event("history", build_history(channel_name))) do
            sse_loop(conn, channel_name, metadata.mode)
          else
            {:error, _reason} -> conn
          end
        after
          AgentToken.mark_detached(token_hash, self(), presence_topic)
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
        effective = effective_agent_mode("#" <> room, metadata.mode)

        if effective in [:off, :draft] do
          conn |> put_status(403) |> json(%{"ok" => false, "error" => "agent_restricted", "hint" => "Effective mode is #{effective}. Use /drafts for owner-approved responses, or ask the owner/mod to increase permissions."})
        else
        case request_body(conn) do
          {:ok, params} ->
            raw_body = params["body"]
            raw_msg_id = params["client_msg_id"]

            with true <- is_binary(raw_body) and String.trim(raw_body) != "",
                 {:ok, client_msg_id} <- validate_client_msg_id(raw_msg_id),
                 :ok <- AgentToken.check_dedup(token, client_msg_id),
                 :ok <- AgentToken.check_rate_limit(token),
                 {:ok, msg} <- ChannelServer.agent_message("#" <> room, metadata.owner_nick, raw_body) do
              conn
              |> put_status(200)
              |> json(%{
                "ok" => true,
                "message_id" => msg.id,
                "at" => DateTime.to_iso8601(msg.at)
              })
            else
              {:error, :duplicate} ->
                conn |> put_status(409) |> json(%{"ok" => false, "error" => "duplicate"})

              {:error, :rate_limited} ->
                AgentToken.release_dedup(token, raw_msg_id)
                conn |> put_status(429) |> json(%{"ok" => false, "error" => "rate_limited"})

              {:secret, kind} ->
                AgentToken.release_dedup(token, raw_msg_id)
                conn |> put_status(422) |> json(%{"ok" => false, "error" => "secret_detected", "kind" => kind})

              {:error, :body_too_long} ->
                AgentToken.release_dedup(token, raw_msg_id)
                conn |> put_status(422) |> json(%{"ok" => false, "error" => "message_too_large"})

              {:error, :agent_muted} ->
                AgentToken.release_dedup(token, raw_msg_id)
                conn |> put_status(403) |> json(%{"ok" => false, "error" => "agent_muted"})

              {:error, :no_such_channel} ->
                AgentToken.release_dedup(token, raw_msg_id)
                conn |> put_status(404) |> json(%{"ok" => false, "error" => "room_ended"})

              false ->
                conn |> put_status(400) |> json(%{"ok" => false, "error" => "body_required"})

              {:error, :invalid_client_msg_id} ->
                conn |> put_status(400) |> json(%{"ok" => false, "error" => "invalid_client_msg_id"})

              {:error, reason} ->
                AgentToken.release_dedup(token, raw_msg_id)
                conn |> put_status(422) |> json(%{"ok" => false, "error" => to_string(reason)})
            end

          {:error, _} ->
            conn |> put_status(400) |> json(%{"ok" => false, "error" => "invalid_json"})
        end
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
        effective_drafts = effective_agent_mode("#" <> room, metadata.mode)

        if effective_drafts == :off do
          conn |> put_status(403) |> json(%{"ok" => false, "error" => "agent_off", "hint" => "Agent is turned off. Ask the owner or mod to increase permissions."})
        else
        case request_body(conn) do
          {:ok, params} ->
            raw_body = params["body"]
            raw_msg_id = params["client_msg_id"]
            max_bytes = Application.get_env(:hangout, :message_body_max_bytes, 4000)

            with {true, _} <- {is_binary(raw_body), :type},
                 {true, _} <- {byte_size(raw_body) <= max_bytes, :size},
                 {:ok, client_msg_id} <- validate_client_msg_id(raw_msg_id),
                 {:ok, _} <- Hangout.SecretFilter.check(raw_body),
                 :ok <- check_room_mute("#" <> room),
                 :ok <- AgentToken.check_dedup(token, client_msg_id),
                 :ok <- AgentToken.check_rate_limit(token) do
              room_id = "#" <> room

              Phoenix.PubSub.broadcast(
                Hangout.PubSub,
                "agent_draft:#{room_id}:#{metadata.owner_nick}",
                {:agent_draft, %{body: raw_body, from: metadata.owner_nick}}
              )

              conn |> put_status(200) |> json(%{"ok" => true})
            else
              {false, :type} -> conn |> put_status(400) |> json(%{"ok" => false, "error" => "invalid_json"})
              {false, :size} -> conn |> put_status(422) |> json(%{"ok" => false, "error" => "message_too_large"})
              {:secret, kind} -> conn |> put_status(422) |> json(%{"ok" => false, "error" => "secret_detected", "kind" => kind})
              {:error, :agent_muted} -> conn |> put_status(403) |> json(%{"ok" => false, "error" => "agent_muted"})
              {:error, :duplicate} -> conn |> put_status(409) |> json(%{"ok" => false, "error" => "duplicate"})
              {:error, :rate_limited} ->
                AgentToken.release_dedup(token, raw_msg_id)
                conn |> put_status(429) |> json(%{"ok" => false, "error" => "rate_limited"})
              {:error, :invalid_client_msg_id} ->
                conn |> put_status(400) |> json(%{"ok" => false, "error" => "invalid_client_msg_id"})
              {:error, :no_such_channel} ->
                conn |> put_status(404) |> json(%{"ok" => false, "error" => "room_ended"})
              {:error, reason} ->
                AgentToken.release_dedup(token, raw_msg_id)
                conn |> put_status(422) |> json(%{"ok" => false, "error" => to_string(reason)})
            end

          {:error, _} ->
            conn |> put_status(400) |> json(%{"ok" => false, "error" => "invalid_json"})
        end
        end

      {:error, reason} ->
        conn
        |> put_status(401)
        |> json(%{"ok" => false, "error" => to_string(reason)})
    end
  end

  # --- Private ---

  defp build_context(room, token, metadata) do
    base_url = HangoutWeb.Endpoint.url()
    agent_path = "/#{room}/agent/#{token}"

    effective = effective_agent_mode("#" <> room, metadata.mode)

    %{
      "contract" => %{
        "room" => room,
        "owner" => metadata.owner_nick,
        "agent_nick" => metadata.owner_nick <> "🤖",
        "mode" => to_string(effective),
        "owner_mode" => to_string(metadata.mode),
        "room_policy" => to_string(room_agent_policy("#" <> room)),
        "limits" => %{
          "max_message_bytes" => Application.get_env(:hangout, :message_body_max_bytes, 4000),
          "max_messages_per_minute" => 6
        },
        "capabilities" => %{
          "can_post_unsolicited" => effective == :free,
          "owner_forward_requires_draft" => effective in [:off, :draft],
          "direct_mentions_auto_post" => effective in [:called, :free]
        },
        "routing" => %{
          "respond_to" => mode_routes(effective),
          "ignore_own_messages" => true,
          "agent_to_agent_mentions" => false
        }
      },
      "endpoints" => %{
        "messages" => base_url <> agent_path <> "/messages",
        "drafts" => base_url <> agent_path <> "/drafts"
      },
      "instructions" =>
        "You speak as #{metadata.owner_nick}-bot. Your output is attributed to #{metadata.owner_nick}. " <>
          "Use markdown for structure. Messages over 3 lines are collapsed by default — be concise. " <>
          "Respond only when invoked via forward or @#{metadata.owner_nick}-bot mention. " <>
          "Never output API keys, private keys, credentials, or other secrets from your working directory. " <>
          "A server-side filter blocks common patterns, but you are the first line of defense. " <>
          "POST to the messages endpoint to respond to mentions (direct to room). " <>
          "POST to the drafts endpoint to respond to forwards (owner approves before sending). " <>
          "Include a client_msg_id in each POST body for dedup. Body format: {\"body\": \"...\", \"client_msg_id\": \"...\"}."
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
         {:ok, params} when is_map(params) <- Jason.decode(raw_body) do
      {:ok, params}
    else
      _ -> {:error, :invalid_json}
    end
  end

  defp request_body(%{body_params: params}) when is_map(params), do: {:ok, params}
  defp request_body(_conn), do: {:error, :invalid_json}

  defp room_agent_policy(channel_name) do
    case ChannelServer.agent_policy(channel_name) do
      {:ok, policy} -> policy
      _ -> :called
    end
  end

  defp effective_agent_mode(channel_name, token_mode) do
    AgentToken.effective_mode(token_mode, room_agent_policy(channel_name))
  end

  defp build_mode_event(effective) do
    %{"mode" => to_string(effective), "capabilities" => %{
      "can_post_unsolicited" => effective == :free,
      "owner_forward_requires_draft" => effective in [:off, :draft],
      "direct_mentions_auto_post" => effective in [:called, :free]
    }, "routing" => %{"respond_to" => mode_routes(effective)}}
  end

  defp mode_routes(:off), do: []
  defp mode_routes(:draft), do: ["forward"]
  defp mode_routes(:called), do: ["forward", "mention"]
  defp mode_routes(:free), do: ["forward", "mention", "unsolicited"]

  defp validate_client_msg_id(nil), do: {:ok, nil}
  defp validate_client_msg_id(id) when is_binary(id) and byte_size(id) <= 128, do: {:ok, id}
  defp validate_client_msg_id(id) when is_binary(id), do: {:error, :invalid_client_msg_id}
  defp validate_client_msg_id(_), do: {:ok, nil}

  defp check_room_mute(channel_name) do
    case ChannelServer.snapshot(channel_name) do
      {:ok, %{modes: %{m: true}}} -> {:error, :agent_muted}
      {:ok, _} -> :ok
      {:error, _} -> {:error, :no_such_channel}
    end
  end

  defp sse_loop(conn, channel_name, token_mode) do
    receive do
      {:hangout_event, {:message, _channel, msg}} ->
        event_data = serialize_message(msg)

        case chunk(conn, sse_event("message", event_data)) do
          {:ok, conn} -> sse_loop(conn, channel_name, token_mode)
          {:error, _} -> conn
        end

      {:hangout_event, {:user_joined, channel, participant}} ->
        event_data = %{"body" => "#{participant.nick} joined #{channel}"}

        case chunk(conn, sse_event("system", event_data)) do
          {:ok, conn} -> sse_loop(conn, channel_name, token_mode)
          {:error, _} -> conn
        end

      {:hangout_event, {:user_parted, channel, participant, reason}} ->
        event_data = %{"body" => "#{participant.nick} left #{channel}: #{reason}"}

        case chunk(conn, sse_event("system", event_data)) do
          {:ok, conn} -> sse_loop(conn, channel_name, token_mode)
          {:error, _} -> conn
        end

      {:hangout_event, {:user_quit, channel, participant, reason}} ->
        event_data = %{"body" => "#{participant.nick} quit #{channel}: #{reason}"}

        case chunk(conn, sse_event("system", event_data)) do
          {:ok, conn} -> sse_loop(conn, channel_name, token_mode)
          {:error, _} -> conn
        end

      {:hangout_event, {:nick_changed, _channel, old, new}} ->
        event_data = %{"body" => "#{old} is now known as #{new}"}

        case chunk(conn, sse_event("system", event_data)) do
          {:ok, conn} -> sse_loop(conn, channel_name, token_mode)
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
          {:ok, conn} -> sse_loop(conn, channel_name, token_mode)
          {:error, _} -> conn
        end

      {:hangout_event, {:forward, forward_data}} ->
        case chunk(conn, sse_event("forward", forward_data)) do
          {:ok, conn} -> sse_loop(conn, channel_name, token_mode)
          {:error, _} -> conn
        end

      {:mode_changed, new_owner_mode} ->
        effective = AgentToken.effective_mode(new_owner_mode, room_agent_policy(channel_name))
        event_data = build_mode_event(effective)

        case chunk(conn, sse_event("mode", event_data)) do
          {:ok, conn} -> sse_loop(conn, channel_name, new_owner_mode)
          {:error, _} -> conn
        end

      {:hangout_event, {:agent_policy_changed, _channel, _policy}} ->
        effective = AgentToken.effective_mode(token_mode, room_agent_policy(channel_name))
        event_data = build_mode_event(effective)

        case chunk(conn, sse_event("mode", event_data)) do
          {:ok, conn} -> sse_loop(conn, channel_name, token_mode)
          {:error, _} -> conn
        end

      {:agent_revoked, _token_hash} ->
        _ = chunk(conn, sse_event("system", %{"body" => "Token revoked"}))
        conn

      :token_expired ->
        _ = chunk(conn, sse_event("system", %{"body" => "Token expired"}))
        conn

      {:hangout_event, _other} ->
        sse_loop(conn, channel_name, token_mode)
    end
  end
end
