defmodule Hangout.Markdown do
  @moduledoc """
  Markdown rendering for chat messages. Detects markdown features
  and renders to sanitized HTML via Earmark.
  """

  @md_patterns [
    ~r/^\#{1,6}\s/m,          # headers
    ~r/```/,                   # fenced code blocks
    ~r/`[^`]+`/,              # inline code
    ~r/\*\*[^*]+\*\*/,       # bold
    ~r/\*[^*]+\*/,           # italic
    ~r/^\s*[-*+]\s/m,        # unordered lists
    ~r/^\s*\d+\.\s/m,        # ordered lists
    ~r/\[.+\]\(.+\)/,        # links
    ~r/^>/m                   # blockquotes
  ]

  @doc "Returns true if the text contains markdown formatting."
  def has_markdown?(text) do
    Enum.any?(@md_patterns, &Regex.match?(&1, text))
  end

  @doc "Render markdown to safe HTML. Returns Phoenix.HTML safe tuple."
  def render(text) do
    text
    |> Earmark.as_html!(escape: true, smartypants: false)
    |> Phoenix.HTML.raw()
  end
end
