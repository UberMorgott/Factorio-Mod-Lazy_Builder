data:extend({
    {
      type = "bool-setting",
      name = "default-radius",
      setting_type = "runtime-per-user",
      default_value = true,
      order = "a"
    },
    {
      type = "int-setting",
      name = "custom-radius",
      setting_type = "runtime-per-user",
      default_value = 10,
      minimum_value = 1,
      maximum_value = 50,
      order = "b"
    },
    {
      type = "bool-setting",
      name = "instant-deconstruction",
      setting_type = "runtime-per-user",
      default_value = false,
      order = "c"
    },
    {
      type = "bool-setting",
      name = "instant-construction",
      setting_type = "runtime-per-user",
      default_value = false,
      order = "d"
    },
    {
      type = "bool-setting",
      name = "instant-upgrade",
      setting_type = "runtime-per-user",
      default_value = false,
      order = "e"
    },
      {
        type = "bool-setting",
        name = "deconstruct-stones-trees",
        setting_type = "runtime-per-user",
        default_value = false,
        order = "f"
      },
    {
      type = "bool-setting",
      name = "nearest-first",
      setting_type = "runtime-per-user",
      default_value = true,
      order = "g"
    }
  })
