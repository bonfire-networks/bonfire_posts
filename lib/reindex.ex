defmodule Bonfire.Posts.Reindex do
  @moduledoc """
  (Re)indexes posts into the search index, in batches.

  Implements `EctoSparkles.DataMigration` (so it reuses the batched, keyset-paginated, throttled
  runner) and registers as a `Bonfire.Common.ReindexModule` so it runs as part of a full search
  backfill via `Bonfire.Search.reindex_all/1`.
  """
  @behaviour EctoSparkles.DataMigration
  @behaviour Bonfire.Common.ReindexModule
  import Ecto.Query
  alias EctoSparkles.DataMigration

  @impl Bonfire.Common.ReindexModule
  def reindex_module, do: __MODULE__

  @impl Bonfire.Common.ReindexModule
  def reindex(opts \\ []), do: DataMigration.Runner.run(__MODULE__, opts)

  # `query_by_origin` has a `:main_object` first binding (so the runner's `where id > ^last_id` and `order_by id` apply). `opts[:origin]` scopes :local (default) / :remote / :all; `include_scheduled: true` so future posts are indexed too (they're filtered out at *search* time until current).
  @impl DataMigration
  def base_query(opts \\ []) do
    Bonfire.Posts.query_by_origin(
      opts[:origin] || :local,
      Keyword.put(opts, :include_scheduled, true)
    )
  end

  @impl DataMigration
  def config do
    # `first_id`: lowest ULID string (Needle.UID-castable), see Bonfire.Me.Users.ReindexLocal.
    %DataMigration.Config{
      batch_size: 50,
      throttle_ms: 2000,
      repo: Bonfire.Common.Repo,
      first_id: "00000000000000000000000000"
    }
  end

  # `maybe_index/3` auto-detects each post's boundary (public vs closed). Per-object for now;
  # batched/pipelined post indexing is a possible follow-up.
  @impl DataMigration
  def migrate(posts) do
    posts
    |> Bonfire.Common.Repo.maybe_preload([:post_content, :created, :replied])
    |> Enum.each(&Bonfire.Search.maybe_index(&1, nil, []))
  end
end
