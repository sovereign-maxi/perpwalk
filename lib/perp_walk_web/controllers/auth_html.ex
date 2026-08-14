defmodule PerpWalkWeb.AuthHTML do
  @moduledoc """
  HTML views for the auth controller.

  Two pages:

  - `new` — the login / generate-keyphrase entry. Two prominent
    buttons; existing users paste their 6-word keyphrase, new
    users mint one.
  - `welcome` — single-shot display of a freshly-minted keyphrase.
    Read once from flash; refresh shows nothing.
  """

  use PerpWalkWeb, :html

  alias PerpWalkWeb.Messages

  embed_templates "auth_html/*"
end
