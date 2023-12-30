defmodule Bonfire.Posts.Repo.Migrations.ImportSocial  do
  @moduledoc false
  use Ecto.Migration

  import Bonfire.Posts.Migrations

  def change, do: migrate_social()
end
