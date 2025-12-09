defmodule Bonfire.Posts.Acts.Posts.Publish do
  @moduledoc """
  Creates a changeset for publishing a post

  Epic Options:
    * `:current_user` - user that will create the post, required.
    * `:post_attrs` (configurable) - attrs to create the post from, required.
    * `:post_id` (configurable) - id to use for the created post (handy for creating
      activitypub objects with an id representing their reported creation time)

  Act Options:
    * `:id` - epic options key to find an id to force override with at, default: `:post_id`
    * `:as` - key to assign changeset to, default: `:post`.
    * `:attrs` - epic options key to find the attributes at, default: `:post_attrs`.
  """

  alias Bonfire.Ecto.Acts.Work
  # alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic

  alias Bonfire.Posts
  alias Ecto.Changeset
  use Arrows
  import Untangle
  import Bonfire.Epics

  # see module documentation
  @doc false
  def run(epic, act) do
    current_user = Bonfire.Common.Utils.current_user(epic.assigns[:options])

    cond do
      epic.errors != [] ->
        maybe_debug(
          epic,
          act,
          length(epic.errors),
          "Skipping due to epic errors"
        )

        epic

      not (is_struct(current_user) or is_binary(current_user)) ->
        maybe_debug(
          epic,
          act,
          current_user,
          "Skipping due to missing current_user"
        )

        epic

      true ->
        as = Keyword.get(act.options, :as, :post)
        id_key = Keyword.get(act.options, :id, :post_id)
        attrs_key = Keyword.get(act.options, :attrs, :post_attrs)
        id = epic.assigns[:options][id_key]
        attrs = Keyword.get(epic.assigns[:options], attrs_key, %{})
        boundary = epic.assigns[:options][:boundary]

        maybe_debug(
          epic,
          act,
          attrs_key,
          "Assigning changeset to :#{as} using attrs"
        )

        # maybe_debug(epic, act, attrs, "Post attrs")
        if attrs == %{}, do: maybe_debug(act, attrs, "empty attrs")

        Posts.changeset(:create, attrs, current_user, boundary)
        |> Map.put(:action, :insert)
        |> maybe_overwrite_id(id, attrs)
        |> Untangle.debug("Post changeset")
        |> Epic.assign(epic, as, ...)
        |> Work.add(:post)
    end
  end

  # If id is nil, check attrs for scheduled_at and generate ULID if present
  defp maybe_overwrite_id(changeset, nil, attrs) do
    scheduled_at =
      Map.get(attrs, :scheduled_at)
      |> debug("scheduled_at attrs value")

    cond do
      is_nil(scheduled_at) or scheduled_at == "" ->
        changeset

      true ->
        dt =
          Bonfire.Common.DatesTimes.to_date_time(scheduled_at)
          |> debug("converted scheduled_at to datetime")

        id =
          (dt && Bonfire.Common.DatesTimes.generate_ulid(dt))
          |> debug("generated ulid from datetime")

        if id do
          Ecto.Changeset.put_change(changeset, :id, id)
        else
          changeset
        end
    end
  end

  defp maybe_overwrite_id(changeset, id, _attrs),
    do: Ecto.Changeset.put_change(changeset, :id, id)
end
