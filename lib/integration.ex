defmodule Bonfire.Posts.Integration do
  use Arrows
  alias Bonfire.Common.Config
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
end
