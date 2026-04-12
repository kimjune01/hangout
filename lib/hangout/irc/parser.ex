defmodule Hangout.IRC.Parser do
  @moduledoc """
  IRC wire protocol parser and formatter (RFC 2812).

  All outbound lines are capped at 512 bytes including the trailing CRLF.
  """

  @line_max Application.compile_env(:hangout, :irc_line_max_bytes, 512)

  # --- Parsing ---

  @doc """
  Parse an IRC line into `{prefix, command, params}`.

  ## Examples

      iex> Hangout.IRC.Parser.parse(":nick!user@host PRIVMSG #channel :hello world")
      {nil, "PRIVMSG", ["#channel", "hello world"]}

      iex> Hangout.IRC.Parser.parse("NICK mynick")
      {nil, "NICK", ["mynick"]}
  """
  def parse(line) do
    line =
      line
      |> to_string()
      |> binary_part(0, min(byte_size(to_string(line)), @line_max - 2))
      |> String.trim_trailing("\r\n")
      |> String.trim_trailing("\n")

    {prefix, rest} =
      case line do
        ":" <> rest ->
          case String.split(rest, " ", parts: 2) do
            [prefix, rest] -> {prefix, rest}
            [prefix] -> {prefix, ""}
          end

        _ ->
          {nil, line}
      end

    {command, params} = parse_params(rest)
    {prefix, String.upcase(command), params}
  end

  defp parse_params(""), do: {"", []}

  defp parse_params(str) do
    case String.split(str, " ", parts: 2) do
      [command, rest] -> {command, parse_param_list(rest, [])}
      [command] -> {command, []}
    end
  end

  defp parse_param_list("", acc), do: Enum.reverse(acc)

  defp parse_param_list(":" <> trailing, acc) do
    Enum.reverse([trailing | acc])
  end

  defp parse_param_list(str, acc) do
    case String.split(str, " ", parts: 2) do
      [param, rest] -> parse_param_list(rest, [param | acc])
      [param] -> Enum.reverse([param | acc])
    end
  end

  # --- Unified line builder ---

  @doc """
  Build a formatted IRC line from prefix, command, and params.
  Automatically adds `:` to trailing param if it contains spaces.
  Truncates to 512 bytes including CRLF.
  """
  def line(prefix, command, params \\ []) do
    body =
      [maybe_prefix(prefix), command | encode_params(params)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    truncate(body <> "\r\n")
  end

  # --- Convenience formatters ---

  @doc "Format a server NOTICE or command: `:hangout <command> <target> :<trailing>`."
  def server_msg(command, target, trailing) do
    line("hangout", command, [target, trailing])
  end

  def server_msg(command, target, middle, trailing) do
    ":hangout #{command} #{target} #{middle} :#{trailing}\r\n" |> truncate()
  end

  @doc "Format a numeric reply."
  def numeric(code, nick, text_or_params) do
    params =
      case text_or_params do
        params when is_list(params) -> params
        text -> [text]
      end

    line("hangout", pad(code), [nick || "*"] ++ params)
  end

  def numeric(code, nick, middle, trailing) when is_integer(code) do
    line("hangout", pad(code), [nick || "*", middle, trailing])
  end

  @doc "Format a user prefix: `nick!user@hangout`."
  def user_prefix(nick, user \\ nil, host \\ "hangout") do
    "#{nick}!#{user || nick}@#{host}"
  end

  @doc "Format a user message: `:nick!user@host COMMAND target :text`."
  def user_msg(nick, user, command, target, text) do
    line(user_prefix(nick, user), command, [target, text])
  end

  @doc "Format a user command without trailing: `:nick!user@host COMMAND params`."
  def user_cmd(nick, user, command, params) do
    line(user_prefix(nick, user), command, [params])
  end

  @doc "Format NAMES reply (353)."
  def names_reply(nick, channel_name, nicks_with_prefix) do
    nick_list = Enum.join(nicks_with_prefix, " ")
    line("hangout", "353", [nick, "=", channel_name, nick_list])
  end

  @doc "Format end of NAMES (366)."
  def end_of_names(nick, channel_name) do
    line("hangout", "366", [nick, channel_name, "End of /NAMES list"])
  end

  @doc "Format a PONG response."
  def pong(token), do: line("hangout", "PONG", ["hangout", token])

  @doc "Format a PING."
  def ping(token), do: "PING :#{token}\r\n"

  # --- Event formatters (used by IRC connection for channel events) ---

  def kick(actor, channel, target, reason) do
    line(user_prefix(actor), "KICK", [channel, target, reason])
  end

  def nick_change(old_nick, new_nick) do
    line(user_prefix(old_nick), "NICK", [new_nick])
  end

  def topic_change(nick, channel, topic) do
    line(user_prefix(nick), "TOPIC", [channel, topic])
  end

  def mode_change(setter, channel, flag, target \\ nil) do
    params = if target, do: [channel, flag, target], else: [channel, flag]
    line(user_prefix(setter), "MODE", params)
  end

  def part(nick, channel, reason) do
    line(user_prefix(nick), "PART", [channel, reason])
  end

  def quit(nick, message) do
    line(user_prefix(nick), "QUIT", [message])
  end

  def who_reply(requester, channel, entry_user, entry_nick, prefix_char, realname) do
    line("hangout", "352", [requester, channel, entry_user, "hangout", "hangout", entry_nick, "H#{prefix_char}", "0 #{realname}"])
  end

  def who_end(nick, channel) do
    line("hangout", "315", [nick, channel, "End of WHO list"])
  end

  def whois_user(requester, nick, user, realname) do
    line("hangout", "311", [requester, nick, user, "hangout", "*", realname])
  end

  def whois_channels(requester, nick, channels_str) do
    line("hangout", "319", [requester, nick, channels_str])
  end

  def whois_end(requester, nick) do
    line("hangout", "318", [requester, nick, "End of WHOIS list"])
  end

  def list_end(nick) do
    line("hangout", "323", [nick, "End of LIST"])
  end

  def isupport(nick) do
    line("hangout", "005", [nick, "CHANTYPES=#", "NICKLEN=16", "CHANNELLEN=48", "CHANMODES=o,v,m,i,t,l", "are supported by this server"])
  end

  def channel_modes(nick, channel, mode_str) do
    line("hangout", "324", [nick, channel, "+#{mode_str}"])
  end

  # --- Validation ---

  @doc "Validate a nick: 1-16 chars, starts with letter, alphanumeric plus IRC specials."
  def valid_nick?(nick) do
    max_len = Application.get_env(:hangout, :max_nick_length, 16)

    Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9_\-\[\]\{\}\\|`^]*$/, nick) and
      String.length(nick) <= max_len
  end

  @doc "Validate a channel name: `#[a-z0-9-]{3,48}`, no leading/trailing hyphen."
  def valid_channel_name?(name) do
    max_len = Application.get_env(:hangout, :max_channel_name_length, 48)

    case name do
      "#" <> slug ->
        String.length(slug) >= 3 and
          String.length(slug) <= max_len and
          Regex.match?(~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/, slug)

      _ ->
        false
    end
  end

  @doc "Check if a target is a channel name (starts with `#`)."
  def channel_name?(target), do: is_binary(target) and String.starts_with?(target, "#")

  @doc "Extract nick from a prefix like `nick!user@host`."
  def nick_from_prefix(prefix) do
    case String.split(prefix, "!", parts: 2) do
      [nick, _] -> nick
      [nick] -> nick
    end
  end

  @doc """
  Check if a PRIVMSG body is a CTCP ACTION.
  Returns `{:action, text}` or `:not_action`.
  """
  def parse_ctcp_action(body) do
    case body do
      <<1, rest::binary>> ->
        rest = String.trim_trailing(rest, <<1>>)

        case rest do
          "ACTION " <> text -> {:action, text}
          _ -> :not_action
        end

      _ ->
        :not_action
    end
  end

  @doc "Parse CTCP ACTION, returning `{:action, text}` or `{:privmsg, body}`."
  def action_body(<<"\x01ACTION ", rest::binary>>) do
    {:action, String.trim_trailing(rest, <<1>>)}
  end

  def action_body(body), do: {:privmsg, body}

  # --- Internal helpers ---

  defp maybe_prefix(nil), do: nil
  defp maybe_prefix(prefix), do: ":" <> prefix

  defp encode_params([]), do: []
  defp encode_params([last]), do: [encode_last(last)]
  defp encode_params([head | tail]), do: [to_string(head) | encode_params(tail)]

  defp encode_last(param) do
    param = to_string(param)

    if param == "" or String.contains?(param, " ") or String.starts_with?(param, ":") do
      ":" <> param
    else
      param
    end
  end

  defp truncate(line) when byte_size(line) <= @line_max, do: line
  defp truncate(line), do: binary_part(line, 0, @line_max - 2) <> "\r\n"

  defp pad(code) when is_integer(code),
    do: code |> Integer.to_string() |> String.pad_leading(3, "0")

  defp pad(code), do: to_string(code)
end
