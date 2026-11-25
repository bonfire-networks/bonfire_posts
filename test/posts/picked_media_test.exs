defmodule Bonfire.Posts.PickedMediaTest do
  @moduledoc """
  Media picked in the composer from the author's own (rather than uploaded again) comes with the form as `upload_metadata[<media id>][media_id]`, beside its alt text, and is attached with the new uploads: the same `Media`, so a file reused in several posts stays one. Only the author's own media can be picked; an alt text changed there is saved on the `Media`, for every post using it.
  """
  use Bonfire.Posts.DataCase, async: false

  import Bonfire.Social.Fake, only: [upload_media: 3]

  alias Bonfire.Files.Media
  alias Bonfire.UI.Common

  setup do
    {:ok, me: fake_user!(), other: fake_user!()}
  end

  defp picked(media, alt \\ nil),
    do: {media.id, %{"media_id" => media.id, "alt" => alt}}

  test "picked media come out with the uploads, the same Media", %{me: me} do
    mine = upload_media(:images, me, "mine")

    assert {%{}, [%Media{id: id}]} =
             Common.live_upload_files_into(%{}, me, Map.new([picked(mine)]), nil)

    assert id == mine.id
  end

  test "someone else's media can't be picked", %{me: me, other: other} do
    theirs = upload_media(:images, other, "theirs")
    # the control: my own is picked in the same form
    mine = upload_media(:images, me, "mine")

    assert {_, media} =
             Common.live_upload_files_into(%{}, me, Map.new([picked(theirs), picked(mine)]), nil)

    assert Enum.map(media, & &1.id) == [mine.id]
  end

  test "an alt text changed in the composer is saved on the Media", %{me: me} do
    mine = upload_media(:images, me, "mine")

    Common.live_upload_files_into(%{}, me, Map.new([picked(mine, "A new description")]), nil)

    assert {:ok, media} = Media.one(id: mine.id)
    assert Media.media_alt(media, false) == "A new description"
  end
end
