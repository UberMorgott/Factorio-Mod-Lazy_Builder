data:extend(
{
  {
    type = "shortcut",
    name = "player-toggle-auto-shortcut",
    order = "c[toggles]-c[my-toggle]",
    action = "lua",
    localised_name = {"shortcut.player-toggle-auto-shortcut"},
    toggleable = true,
    toggled = true,
    icon = "__auto-build-and-deconstruct__/graphics/icons/abad_icon_32x24.png",
    icon_size = 32,
    small_icon  = "__auto-build-and-deconstruct__/graphics/icons/abad_icon_32x24.png",
    small_icon_size = 24
  },
  {
    type = "custom-input",
    name = "player-toggle-auto-input",
    key_sequence = "CONTROL + B",
    consuming = "game-only",
	localised_name = {"controls.player-toggle-auto-input"},
  }
})
