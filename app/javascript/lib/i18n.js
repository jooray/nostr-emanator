// Client-side lookups into the `js:` subtree of config/locales, which the
// layout embeds as JSON (layouts/_i18n_head). Same %{name} interpolation as
// Rails. A value that is an object is a plural table (one/few/many/other),
// chosen with Intl.PluralRules when `count` is passed.
let table = null

function load() {
  if (table) return table
  try {
    table = JSON.parse(document.getElementById("i18n-js")?.textContent || "{}")
  } catch {
    table = {}
  }
  return table
}

export function locale() {
  return document.documentElement.lang || "en"
}

export function t(key, vars = {}) {
  let value = key.split(".").reduce((node, part) => node?.[part], load())
  if (value && typeof value === "object" && "count" in vars) {
    const form = new Intl.PluralRules(locale()).select(vars.count)
    value = value[form] ?? value.other
  }
  if (typeof value !== "string") return key
  return value.replace(/%\{(\w+)\}/g, (match, name) => (name in vars ? String(vars[name]) : match))
}
