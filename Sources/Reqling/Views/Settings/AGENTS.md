## Settings Screen

These instructions cover the settings UI under `Sources/Reqling/Views/Settings/`.

- **Build rows from the shared settings types.** Use `SettingsFormSection` and `SettingsFormRow` for cards and rows, `SettingsResponsiveControlRow` for label/control pairs, and `SettingsErrorLabel` for a row's failure; `SettingsControlHorizontalSizing` documents which controls fill and which hug.
- **Use `SettingsToggleRow` for boolean rows and `SettingsToggleControl` for compact headers.** They share switch styling, row-click toggling, press feedback, and accessibility; keep selectable details and secondary actions outside the toggle's label.
- **Keep settings navigation reachable.** `SettingsScreen` switches from the side list to the scrolling chip strip before the side list can be clipped.
- Keep pages sorted alphabetically by title. `SettingsPage.allCases` drives the side list and the chip strip, so update the enum order, `SettingsDetail`'s switch, and the Settings snapshots together.
