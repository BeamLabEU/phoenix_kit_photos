# Dialyzer warnings to ignore (matched by dialyxir). Each entry is scoped to one file and
# one warning type, so anything new in the same file still surfaces.
[
  # Gettext compiles the catalogues' `Plural-Forms` header into a literal (opaque)
  # `%Expo.PluralForms{}` and passes it to `Gettext.Plural.plural/2` from inside the
  # generated backend. That is code we do not author, and the value is right at runtime
  # (the ru catalogue's nplurals=3 is what surfaces it). The same skip as the other
  # phoenix_kit_* packages with a Gettext backend of their own.
  {"lib/phoenix_kit_photos/gettext.ex", :call_without_opaque},

  # `phoenix_kit_comments` is optional: the info panel calls it only when the host has it
  # (`Code.ensure_loaded?/1`, and `@compile {:no_warn_undefined, ...}` for the compiler).
  # It is not a dependency, so it is not in the PLT and its `enabled?/0` looks unknown.
  {"lib/phoenix_kit_photos/components/info_panel.ex", :unknown_function}
]
