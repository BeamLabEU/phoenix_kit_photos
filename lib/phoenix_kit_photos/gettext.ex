defmodule PhoenixKitPhotos.Gettext do
  @moduledoc """
  Gettext backend for labels this package hands to the browser.

  Month names are translated here, then sent to the hook already formatted.
  The hook never chooses an English month name of its own.
  """

  use Gettext.Backend, otp_app: :phoenix_kit_photos
end
