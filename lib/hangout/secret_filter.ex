defmodule Hangout.SecretFilter do
  @moduledoc """
  Detects likely secrets in message text to prevent accidental leakage.
  Not a security boundary — a pokayoke for common oopsies.
  """

  @patterns [
    # PEM-encoded keys
    {~r/-----BEGIN\s+(RSA|EC|DSA|PGP|OPENSSH|ENCRYPTED)?\s*PRIVATE KEY-----/, "private key"},
    {~r/-----BEGIN\s+CERTIFICATE-----/, "certificate"},

    # AWS
    {~r/(A3T[A-Z0-9]|AKIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA|ASIA)[A-Z0-9]{16}/, "AWS key"},

    # GitHub
    {~r/ghp_[0-9a-zA-Z]{36}/, "GitHub token"},
    {~r/github_pat_[a-zA-Z0-9_]{82}/, "GitHub PAT"},
    {~r/gho_[0-9a-zA-Z]{36}/, "GitHub OAuth token"},
    {~r/ghs_[0-9a-zA-Z]{36}/, "GitHub server token"},

    # Stripe
    {~r/sk_live_[0-9a-zA-Z]{24,}/, "Stripe secret key"},
    {~r/rk_live_[0-9a-zA-Z]{24,}/, "Stripe restricted key"},

    # Slack
    {~r/xoxb-[0-9]{11,13}-[0-9]{11,13}-[0-9a-zA-Z]{24}/, "Slack bot token"},
    {~r/xoxp-[0-9]{11,13}-[0-9]{11,13}-[0-9a-zA-Z]{24}/, "Slack user token"},

    # AI inference API keys
    {~r/sk-[a-zA-Z0-9]{32,}/, "OpenAI API key"},
    {~r/sk-ant-[a-zA-Z0-9-]{80,}/, "Anthropic API key"},

    # Credit card numbers (Luhn-plausible 13-19 digit sequences)
    {~r/\b(?:4[0-9]{12}(?:[0-9]{3})?|5[1-5][0-9]{14}|3[47][0-9]{13}|3(?:0[0-5]|[68][0-9])[0-9]{11}|6(?:011|5[0-9]{2})[0-9]{12}|(?:2131|1800|35\d{3})\d{11})\b/, "credit card number"},

    # Generic high-entropy (hex keys 32+ chars, base64 keys 40+ chars)
    {~r/(?:api[_-]?key|secret[_-]?key|access[_-]?token|private[_-]?key)\s*[=:]\s*['"]?[A-Za-z0-9+\/=_-]{32,}['"]?/i, "API key assignment"},

    # Crypto seed phrases (12 or 24 lowercase words)
    {~r/\b(?:[a-z]{3,8}\s+){11,23}[a-z]{3,8}\b/, "possible recovery phrase"},
  ]

  @doc """
  Returns `{:ok, text}` if the message looks clean,
  or `{:secret, kind}` if it matches a known secret pattern.
  """
  def check(text) do
    Enum.find_value(@patterns, {:ok, text}, fn {pattern, kind} ->
      if Regex.match?(pattern, text), do: {:secret, kind}
    end)
  end
end
