defmodule Bonfire.Posts.Migrations do
  @moduledoc false
  use Ecto.Migration
  import Pointers.Migration

  def ms(:up) do
    quote do
      require Bonfire.Data.Social.Post.Migration
      require Bonfire.Data.Social.PostContent.Migration

      Bonfire.Data.Social.Post.Migration.migrate_post()
      Bonfire.Data.Social.PostContent.Migration.migrate_post_content()
    end
  end

  def ms(:down) do
    quote do
      require Bonfire.Data.Social.Post.Migration
      require Bonfire.Data.Social.PostContent.Migration

      Bonfire.Data.Social.PostContent.Migration.migrate_post_content()
      Bonfire.Data.Social.Post.Migration.migrate_post()
    end
  end

  defmacro migrate_social() do
    quote do
      if Ecto.Migration.direction() == :up,
        do: unquote(ms(:up)),
        else: unquote(ms(:down))
    end
  end

  defmacro migrate_social(dir), do: ms(dir)
end
