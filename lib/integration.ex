defmodule Bonfire.Posts.Integration do
  use Arrows
  use Bonfire.Common.Config
  use Bonfire.Common.Utils
  # alias Bonfire.Data.Social.Follow
  # import Untangle

  declare_extension("Posts",
    icon: "icomoon-free:blog",
    emoji: "📝",
    description: l("Functionality for writing and reading posts.")
  )

  def repo, do: Config.repo()

  def mailer, do: Config.get!(:mailer_module)

  def article_char_threshold, do: Config.get([:bonfire_posts, :article_char_threshold], 888)
end
