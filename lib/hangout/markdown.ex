defmodule Hangout.Markdown do
  @moduledoc """
  Markdown rendering for chat messages. Renders via Earmark,
  then sanitizes HTML to a strict allowlist.
  """

  @md_patterns [
    ~r/^\#{1,6}\s/m,          # headers
    ~r/```/,                   # fenced code blocks
    ~r/`[^`]+`/,              # inline code
    ~r/\*\*[^*]+\*\*/,       # bold
    ~r/\[.+\]\(https?:\/\//,  # links (safe schemes only)
    ~r/^\s*[-*+]\s\S/m,      # unordered lists (require content after marker)
    ~r/^\s*\d+\.\s\S/m,      # ordered lists
    ~r/^>\s/m                 # blockquotes
  ]

  @allowed_tags ~w(p strong em code pre blockquote ul ol li a br h1 h2 h3 h4 h5 h6)
  @allowed_attrs %{"a" => ["href"]}
  @safe_schemes ["http", "https", "mailto"]

  @doc "Returns true if the text contains markdown formatting."
  def has_markdown?(text) do
    Enum.any?(@md_patterns, &Regex.match?(&1, text))
  end

  @doc "Render markdown to sanitized safe HTML."
  def render(text) do
    text
    |> Earmark.as_html!(smartypants: false)
    |> sanitize_html()
    |> Phoenix.HTML.raw()
  end

  defp sanitize_html(html) do
    # Strip all tags not in allowlist, strip all attributes not in allowlist,
    # validate href schemes
    html
    |> strip_dangerous_tags()
    |> strip_dangerous_attrs()
    |> sanitize_links()
  end

  defp strip_dangerous_tags(html) do
    # Remove any tag not in the allowlist
    allowed_pattern = Enum.join(@allowed_tags, "|")
    # Keep allowed opening/closing tags, strip everything else
    Regex.replace(
      ~r/<\/?(?!(?:#{allowed_pattern})\b)[a-zA-Z][^>]*>/,
      html,
      ""
    )
  end

  defp strip_dangerous_attrs(html) do
    # Remove event handlers and dangerous attributes from all tags
    Regex.replace(
      ~r/\s+(?:on\w+|style|class|id|src|srcset|data-\w+)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/i,
      html,
      ""
    )
  end

  defp sanitize_links(html) do
    Regex.replace(~r/href\s*=\s*"([^"]*)"/i, html, fn full, url ->
      uri = URI.parse(String.trim(url))

      if uri.scheme == nil or uri.scheme in @safe_schemes do
        full
      else
        ~s(href="#")
      end
    end)
  end
end
