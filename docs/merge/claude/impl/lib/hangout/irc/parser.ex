defmodule Hangout.IRC.Parser do
  @moduledoc """
  IRC wire protocol parser and formatter (RFC 2812).
  """

  @doc """
  Parse an IRC line into `{prefix, command, params}`.

  ## Examples

      iex> Parser.parse(":nick!user@host PRIVMSG #channel :hello world")
      {"nick!user@host", "PRIVMSG", ["#channel", "hello world"]}

      iex> Parser.parse("NICK mynick")
      {nil, "NICK", ["mynick"]}
  """
  def parse(line) do
    line = String.trim_trailing(line, "\r\n") |> String.trim_trailing("\n")

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

  # --- Formatters ---

  @doc """
  Format a server message: `:hangout <numeric/command> <target> <params>`.
  """
  def server_msg(command, target, trailing) do
    ":hangout #{command} #{target} :#{trailing}\r\n"
  end

  def server_msg(command, target, middle, trailing) do
    ":hangout #{command} #{target} #{middle} :#{trailing}\r\n"
  end

  @doc """
  Format a numeric reply.
  """
  def numeric(code, nick, trailing) when is_integer(code) do
    code_str = code |> Integer.to_string() |> String.pad_leading(3, "0")
    ":hangout #{code_str} #{nick} :#{trailing}\r\n"
  end

  def numeric(code, nick, middle, trailing) when is_integer(code) do
    code_str = code |> Integer.to_string() |> String.pad_leading(3, "0")
    ":hangout #{code_str} #{nick} #{middle} :#{trailing}\r\n"
  end

  @doc """
  Format a user message: `:nick!user@host COMMAND target :text`.
  """
  def user_msg(nick, user, command, target, text) do
    ":#{nick}!#{user}@hangout #{command} #{target} :#{text}\r\n"
  end

  @doc """
  Format a user message without trailing: `:nick!user@host COMMAND params`.
  """
  def user_cmd(nick, user, command, params) do
    ":#{nick}!#{user}@hangout #{command} #{params}\r\n"
  end

  @doc """
  Format NAMES reply (353).
  """
  def names_reply(nick, channel_name, nicks_with_prefix) do
    nick_list = Enum.join(nicks_with_prefix, " ")
    ":hangout 353 #{nick} = #{channel_name} :#{nick_list}\r\n"
  end

  @doc """
  Format end of NAMES (366).
  """
  def end_of_names(nick, channel_name) do
    ":hangout 366 #{nick} #{channel_name} :End of /NAMES list\r\n"
  end

  @doc """
  Format a PONG response.
  """
  def pong(token) do
    ":hangout PONG hangout :#{token}\r\n"
  end

  @doc """
  Format a PING.
  """
  def ping(token) do
    "PING :#{token}\r\n"
  end

  @doc """
  Validate a nick against IRC rules: 1-16 chars, starts with letter.
  """
  def valid_nick?(nick) do
    max_len = Application.get_env(:hangout, :max_nick_length, 16)
    Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9_\-\[\]\{\}\\|`^]*$/, nick) and
      String.length(nick) <= max_len
  end

  @doc """
  Validate a channel name: #[a-z0-9-]{3,48}, no leading/trailing hyphen.
  """
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

  @doc """
  Extract nick from a prefix like "nick!user@host".
  """
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
end
