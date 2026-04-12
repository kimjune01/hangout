defmodule Hangout.Naming do
  @moduledoc "Shared nick and room slug generation."

  @adjectives ~w(quiet green bright calm swift bold dark warm cool soft)
  @nouns ~w(fox lamp river cloud storm wind leaf spark wave flame)

  def random_nick do
    "#{Enum.random(@adjectives)}-#{Enum.random(@nouns)}"
  end

  def random_slug do
    "#{Enum.random(@adjectives)}-#{Enum.random(@nouns)}-#{:rand.uniform(99)}"
  end

  def slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end
end
