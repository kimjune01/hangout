defmodule Hangout.IRC.Parser do
  @moduledoc "IRC line parser and formatter."

  @line_max Application.compile_env(:hangout, :irc_line_max_bytes, 512)

  def parse(line) when is_binary(line) do
    line =
      line
      |> binary_part(0, min(byte_size(line), @line_max - 2))
      |> String.trim_trailing("\r\n")

    {prefix, rest} =
      if String.starts_with?(line, ":") do
        [prefix, rest] = String.split(String.trim_leading(line, ":"), " ", parts: 2)
        {prefix, rest}
      else
        {nil, line}
      end

    {params, trailing} =
      case String.split(rest, " :", parts: 2) do
        [before, after_] -> {split_params(before), after_}
        [before] -> {split_params(before), nil}
      end

    case params do
      [cmd | args] ->
        {:ok, %{prefix: prefix, command: String.upcase(cmd), params: args ++ maybe_trailing(trailing)}}

      [] ->
        {:error, :empty}
    end
  end

  def line(prefix, command, params \\ []) do
    body =
      [maybe_prefix(prefix), command | encode_params(params)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    truncate(body <> "\r\n")
  end

  def numeric(code, nick, text_or_params) do
    params =
      case text_or_params do
        params when is_list(params) -> params
        text -> [text]
      end

    line("hangout", pad(code), [nick || "*"] ++ params)
  end

  def user_prefix(nick, user \\ nil, host \\ "hangout") do
    "#{nick}!#{user || nick}@#{host}"
  end

  def channel_name?(target), do: is_binary(target) and String.starts_with?(target, "#")

  def action_body(<<"\x01ACTION ", rest::binary>>) do
    {:action, String.trim_trailing(rest, <<1>>)}
  end

  def action_body(body), do: {:privmsg, body}

  defp split_params(""), do: []
  defp split_params(s), do: String.split(s, " ", trim: true)

  defp maybe_trailing(nil), do: []
  defp maybe_trailing(text), do: [text]

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

  defp pad(code) when is_integer(code), do: code |> Integer.to_string() |> String.pad_leading(3, "0")
  defp pad(code), do: code
end
