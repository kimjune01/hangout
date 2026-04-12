defmodule Hangout.IRC.ParserTest do
  use ExUnit.Case, async: true

  alias Hangout.IRC.Parser

  @line_max 512

  # --- Property: all formatters produce lines ≤ 512 bytes ---

  describe "line length invariant" do
    test "server_msg respects 512-byte limit" do
      long_text = String.duplicate("x", 600)
      line = Parser.server_msg("NOTICE", "#channel", long_text)
      assert byte_size(line) <= @line_max
      assert String.ends_with?(line, "\r\n")
    end

    test "numeric respects 512-byte limit" do
      long_text = String.duplicate("y", 600)
      line = Parser.numeric(332, "nick", ["#channel", long_text])
      assert byte_size(line) <= @line_max
    end

    test "user_msg respects 512-byte limit" do
      long_body = String.duplicate("z", 600)
      line = Parser.user_msg("nick", "user", "PRIVMSG", "#channel", long_body)
      assert byte_size(line) <= @line_max
    end

    test "kick respects 512-byte limit" do
      long_reason = String.duplicate("r", 600)
      line = Parser.kick("mod", "#channel", "target", long_reason)
      assert byte_size(line) <= @line_max
    end

    test "who_reply respects 512-byte limit" do
      long_realname = String.duplicate("n", 600)
      line = Parser.who_reply("req", "#ch", "user", "nick", "@", long_realname)
      assert byte_size(line) <= @line_max
    end

    test "isupport respects 512-byte limit" do
      line = Parser.isupport("nick")
      assert byte_size(line) <= @line_max
    end

    test "names_reply respects 512-byte limit" do
      nicks = for i <- 1..100, do: "user#{i}"
      line = Parser.names_reply("me", "#channel", nicks)
      assert byte_size(line) <= @line_max
    end

    test "all formatters end with CRLF" do
      lines = [
        Parser.server_msg("NOTICE", "#ch", "hello"),
        Parser.numeric(1, "nick", "Welcome"),
        Parser.user_msg("a", "a", "PRIVMSG", "#ch", "hi"),
        Parser.user_cmd("a", "a", "JOIN", "#ch"),
        Parser.names_reply("a", "#ch", ["a", "b"]),
        Parser.end_of_names("a", "#ch"),
        Parser.pong("token"),
        Parser.kick("mod", "#ch", "target", "reason"),
        Parser.nick_change("old", "new"),
        Parser.topic_change("nick", "#ch", "topic"),
        Parser.mode_change("nick", "#ch", "+i"),
        Parser.mode_change("nick", "#ch", "+o", "target"),
        Parser.part("nick", "#ch", "bye"),
        Parser.quit("nick", "leaving"),
        Parser.who_reply("req", "#ch", "user", "nick", "@", "Real"),
        Parser.who_end("req", "#ch"),
        Parser.whois_user("req", "nick", "user", "Real Name"),
        Parser.whois_channels("req", "nick", "#ch1 #ch2"),
        Parser.whois_end("req", "nick"),
        Parser.list_end("nick"),
        Parser.isupport("nick"),
        Parser.channel_modes("nick", "#ch", "im")
      ]

      for line <- lines do
        assert String.ends_with?(line, "\r\n"), "Missing CRLF in: #{inspect(line)}"
        assert byte_size(line) <= @line_max, "Over 512 bytes: #{byte_size(line)}"
      end
    end
  end

  # --- Parse edge cases ---

  describe "parse/1" do
    test "simple command" do
      assert {nil, "NICK", ["mynick"]} = Parser.parse("NICK mynick")
    end

    test "command with prefix" do
      {prefix, "PRIVMSG", ["#channel", "hello world"]} =
        Parser.parse(":nick!user@host PRIVMSG #channel :hello world")

      assert prefix == "nick!user@host"
    end

    test "trailing parameter with spaces" do
      {_, "PRIVMSG", [_, body]} = Parser.parse(":n!u@h PRIVMSG #ch :hello there world")
      assert body == "hello there world"
    end

    test "empty trailing parameter" do
      {_, "TOPIC", ["#ch", ""]} = Parser.parse(":n!u@h TOPIC #ch :")
    end

    test "no parameters" do
      {nil, "QUIT", []} = Parser.parse("QUIT")
    end

    test "QUIT with trailing" do
      {nil, "QUIT", ["goodbye"]} = Parser.parse("QUIT :goodbye")
    end

    test "multiple middle params" do
      {_, "MODE", ["#ch", "+o", "nick"]} = Parser.parse(":s MODE #ch +o nick")
    end

    test "strips CRLF and LF" do
      {nil, "PING", ["token"]} = Parser.parse("PING token\r\n")
      {nil, "PING", ["token"]} = Parser.parse("PING token\n")
    end

    test "empty string" do
      {nil, "", []} = Parser.parse("")
    end

    test "overlong line is truncated before parse" do
      long = "PRIVMSG #ch :" <> String.duplicate("x", 600)
      {nil, "PRIVMSG", ["#ch", body]} = Parser.parse(long)
      # Body should be truncated
      assert String.length(body) < 600
    end
  end

  # --- Validation ---

  describe "valid_nick?/1" do
    test "valid nicks" do
      assert Parser.valid_nick?("alice")
      assert Parser.valid_nick?("Bob123")
      assert Parser.valid_nick?("a")
      assert Parser.valid_nick?("nick_name")
      assert Parser.valid_nick?("nick-name")
    end

    test "invalid nicks" do
      refute Parser.valid_nick?("")
      refute Parser.valid_nick?("123abc")  # starts with digit
      refute Parser.valid_nick?("nick name")  # space
      refute Parser.valid_nick?(String.duplicate("a", 17))  # too long
    end
  end

  describe "valid_channel_name?/1" do
    test "valid channel names" do
      assert Parser.valid_channel_name?("#abc")
      assert Parser.valid_channel_name?("#calc-study")
      assert Parser.valid_channel_name?("#room-42")
    end

    test "invalid channel names" do
      refute Parser.valid_channel_name?("abc")  # no #
      refute Parser.valid_channel_name?("#ab")  # too short (< 3 after #)
      refute Parser.valid_channel_name?("#-abc")  # leading hyphen
      refute Parser.valid_channel_name?("#ABC")  # uppercase
    end
  end

  # --- CTCP ACTION ---

  describe "parse_ctcp_action/1" do
    test "detects ACTION" do
      assert {:action, "waves"} = Parser.parse_ctcp_action("\x01ACTION waves\x01")
    end

    test "non-action is passthrough" do
      assert :not_action = Parser.parse_ctcp_action("hello")
    end
  end
end
