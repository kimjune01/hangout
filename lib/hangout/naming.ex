defmodule Hangout.Naming do
  @moduledoc "Shared nick and room slug generation."

  @adjectives ~w(sweaty crusty moist chunky dirty feral unhinged floppy soggy shifty salty greasy wonky sketchy lumpy rusty rancid janky thick raw)
  @nouns ~w(goblin turnip badger sock toad bucket wrench pork noodle clam waffle donkey pickle grub hog plunger stump rump muffin)

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
