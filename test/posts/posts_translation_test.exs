defmodule Bonfire.Posts.PostsTranslationTest do
  use Bonfire.Posts.DataCase, async: true
  use Bonfire.Common.Utils

  alias Bonfire.Social.FeedActivities
  alias Bonfire.Posts
  alias Bonfire.Me.Fake
  import Bonfire.Social.Fake
  use Bonfire.Common.Utils
  import Tesla.Mock

  defp assert_translations(post_content) do
    # Ensure original content is in English
    assert post_content.summary == "Hello world"
    assert post_content.html_body == "This is the body"

    # Translate to Spanish
    post_es = Cldr.Trans.Translator.translate(post_content, :es)
    assert post_es.summary == "Hola mundo"
    assert post_es.html_body == "Este es el cuerpo"

    # Translate to a non-existent locale, should fallback to default
    post_de = Cldr.Trans.Translator.translate(post_content, :de)
    assert post_de.summary == "Hello world"
    assert post_de.html_body == "This is the body"

    # Translate with a fallback chain
    post_fallback = Cldr.Trans.Translator.translate(post_content, [:de, :es])
    assert post_fallback.summary == "Hola mundo"
    assert post_fallback.html_body == "Este es el cuerpo"
  end

  setup do
    user = Fake.fake_user!()

    post =
      fake_post!(user, "public", %{
        post_content: %{
          summary: "Hello world",
          html_body: "This is the body",
          translations: %{
            "es" => %{
              "summary" => "Hola mundo",
              "html_body" => "Este es el cuerpo"
            }
          }
        }
      })

    post_en_only =
      fake_post!(user, "public", %{
        post_content: %{
          summary: "English only",
          html_body: "Just English"
        }
      })

    {:ok, user: user, post: post, post_en_only: post_en_only}
  end

  test "can translate post content with translations", %{post: post} do
    assert_translations(post.post_content)
  end

  test "can translate post content after read", %{post: post} do
    {:ok, read_post} = Posts.read(post.id)
    assert_translations(read_post.post_content)
  end

  test "translation fragment returns correct values", %{post: post, post_en_only: post_en_only} do
    # Debug: check the actual JSON structure in the DB
    db_json =
      repo().one(
        from pc in Bonfire.Data.Social.PostContent,
          where: pc.id == ^post.id,
          select: fragment("row_to_json(?)", pc)
      )
      |> flood("DB post_content JSON")

    # Debug: check the output of translate_field directly in SQL
    translated_summary =
      repo().one(
        from pc in Bonfire.Data.Social.PostContent,
          where: pc.id == ^post.id,
          select:
            fragment(
              "translate_field(?, ?::varchar, ?::varchar, ?::varchar, ?::varchar[])",
              pc,
              "translations",
              "summary",
              "en",
              ^["es"]
            )
      )
      |> flood("translate_field summary :es")

    db_json_en_only =
      repo().one(
        from pc in Bonfire.Data.Social.PostContent,
          where: pc.id == ^post.id,
          select: fragment("row_to_json(?)", pc)
      )
      |> flood("DB post_content JSON")

    translated_summary_en_only =
      repo().one(
        from pc in Bonfire.Data.Social.PostContent,
          where: pc.id == ^post.id,
          select:
            fragment(
              "translate_field(?, ?::varchar, ?::varchar, ?::varchar, ?::varchar[])",
              pc,
              "translations",
              "summary",
              "en",
              ^["es"]
            )
      )
      |> flood("translate_field summary :es ")

    import Ecto.Query

    # Query for display in preferred_language for Spanish
    query =
      Bonfire.Data.Social.Post
      |> where([p], p.id == ^post.id)
      |> Bonfire.Social.Objects.select_preferred_language(:es)
      |> flood("Query in preferred language :es query")

    results =
      repo().all(query)
      |> flood("Posts in preferred language :es")

    # The fields should be translated
    found_post = Enum.find(results, fn post -> post.id == post.id end)
    assert found_post.activity.object.post_content.translation["summary"] == "Hola mundo"
    assert found_post.activity.object.post_content.translation["html_body"] == "Este es el cuerpo"
  end

  @tag :fixme
  test "filtered query only returns posts with Spanish translation", %{
    post: post,
    post_en_only: post_en_only
  } do
    import Ecto.Query

    # debug: check the output of translation subquery

    translations =
      repo().all(
        from pc in Bonfire.Data.Social.PostContent,
          select:
            {pc.id,
             fragment(
               "translate_field(?, ?::varchar, ?::varchar[])",
               pc,
               "translations",
               ^["es"]
             )}
      )
      |> flood("Translation subquery output for :es")

    q = """
    DO $$
    DECLARE
      rec RECORD;
    BEGIN
      FOR rec IN 
        SELECT b0."id", s3."translation", s3."summary"
        FROM "bonfire_data_social_post" AS b0 
        LEFT OUTER JOIN "bonfire_data_social_activity" AS b1 ON b1."id" = b0."id" 
        LEFT OUTER JOIN "pointers_pointer" AS p2 ON p2."id" = b1."object_id" 
        LEFT OUTER JOIN (
          SELECT sb0."id", sb0."summary", translate_field(sb0, 'en', ARRAY['es']) AS "translation" 
          FROM "bonfire_data_social_post_content" AS sb0
        ) AS s3 ON s3."id" = p2."id" 
         WHERE (NOT (s3."translation" IS NULL))
      LOOP
        IF rec.translation IS NULL THEN
          RAISE EXCEPTION 'Found: id=%, translation=%, summary=%', rec.id, rec.translation, rec.summary;
        END IF;
      END LOOP;
    END $$;
    """

    repo().sql(q)

    # now try filtering - FIXME: still shows untranslated posts
    query =
      Bonfire.Data.Social.Post
      |> Bonfire.Social.Objects.maybe_filter({:preferred_language, [:es]}, [])
      |> flood("Query filtered for preferred language :es query")
      |> repo().print_sql()

    results =
      repo().all(query)
      |> flood("Posts filtered for preferred language :es")

    # Only the post with Spanish translation should be returned
    assert Enum.any?(results, fn post -> post.id == post.id end)
    refute Enum.any?(results, fn post -> post.id == post_en_only.id end)

    # The fields should also be translated
    found_post = Enum.find(results, fn post -> post.id == post.id end)
    assert found_post.activity.object.post_content.translation["summary"] == "Hola mundo"
    assert found_post.activity.object.post_content.translation["html_body"] == "Este es el cuerpo"
  end

  test "can set primary language on post" do
    user = Bonfire.Me.Fake.fake_user!()
    assert :fr in Bonfire.Common.Localise.known_locales()

    post =
      fake_post!(user, "public", %{
        language: "fr",
        post_content: %{
          summary: "French only",
          html_body: "Just French"
        }
      })
      |> repo().maybe_preload(:language)

    assert post.language.locale == "fr"

    {:ok, read_post} =
      Posts.read(post.id)
      # TODO: should language be included in preloads by default?
      |> repo().maybe_preload(:language)

    assert read_post.language.locale == "fr"
  end

  test "cannot set invalid primary language on post" do
    user = Bonfire.Me.Fake.fake_user!()
    assert :xx not in Bonfire.Common.Localise.known_locales()

    assert_raise RuntimeError, fn ->
      fake_post!(user, "public", %{
        language: "xx",
        post_content: %{
          html_body: "Random language content"
        }
      })
    end

    #     |> repo().maybe_preload(:language)
    # assert is_nil(post.language) # or is_nil(post.language.locale)
  end
end
