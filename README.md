# multi-profile

> [!CAUTION]
> This project in its entirety is slopped. Do not use in production unless you understand the risks.

Declarative, **isolated Zen/Firefox profiles** — one per customer / MS Teams
tenant — built with Nix and used from a per-customer
[direnv](https://direnv.net/).

Each profile is a wrapped browser with **extensions and bookmarks baked in as
code**, plus a launcher that keeps the *runtime* profile (cookies, sessions,
your Teams login) in a directory next to the direnv. So:

- every customer gets a separate Microsoft/Teams login — no account switching;
- they run **concurrently and fully isolated** from each other and from your
  personal browser;
- config (extensions, bookmarks, prefs) is reproducible and version-controlled;
- the only state on disk per direnv is `./.browser-profiles/<name>/` (gitignored).

## How it works

- **Extensions** are installed via the enterprise `ExtensionSettings` policy
  (`installation_mode = "force_installed"`), so they're always present, enabled
  and pinned. Packages come from
  [`nur.repos.rycee.firefox-addons`](https://github.com/nix-community/nur).
- **Bookmarks** use the `ManagedBookmarks` policy — a read-only folder that
  always reflects your config, including nested folders.
- **Prefs** (container tabs, homepage, telemetry off, first-run/onboarding
  skipped, …) are baked into the browser's `mozilla.cfg`. A fresh profile opens
  straight to your homepage — no Firefox `about:welcome`, no post-update page,
  no "make me default" nag. Zen's own welcome screen ("a calmer internet") is
  special: it ships `zen.welcome-screen.seen=false` as an app default that a
  `mozilla.cfg` pref doesn't reliably override, so the launcher seeds it on the
  user branch via a managed `user.js` (the mechanism Zen's own tests use).
- All of the above are applied by `wrapFirefox` **for Firefox**. **Zen** ignores
  `wrapFirefox`'s `policies.json`/`mozilla.cfg` (it reads config from its own
  packaged `distribution/`), so for Zen the policies are baked into the
  `zen-browser-flake` package via its `policies` arg, and prefs are delivered
  through a managed `user.js` in the profile. Same config, different plumbing.
- The **launcher** runs `… --no-remote --profile $PWD/.browser-profiles/<name>`.

Defaults extensions: **uBlock Origin, Bitwarden, FoxyProxy, Wappalyzer, DeArrow,
SponsorBlock**.

## Quick start (try the demo)

```sh
nix run github:YOU/multi-profile#demo     # a Firefox profile w/ all defaults
```

## Real usage: public main flake + private work flake

The design splits cleanly so your **main flake can be public** while customer
data lives in a **private work flake**. Both contribute profiles.

### 1. The private work flake (`work`)

Pure data, **no inputs** — nothing leaks into a public repo. See
[`examples/work/flake.nix`](examples/work/flake.nix):

```nix
{
  outputs = { self }: {
    browserProfiles = {
      acme = {
        browser = "zen";
        bookmarks = [
          { name = "Teams"; url = "https://teams.microsoft.com"; }
          { name = "Azure"; children = [
              { name = "Portal"; url = "https://portal.azure.com"; }
          ]; }
        ];
        settings."browser.startup.homepage" = "https://teams.microsoft.com";
      };
    };
  };
}
```

### 2. Your public main flake

`nix flake init -t github:YOU/multi-profile` gives you
[`templates/main`](templates/main). It merges work's profiles with your own:

```nix
{
  inputs = {
    multi-profile.url = "github:YOU/multi-profile";
    work.url = "git+ssh://git@your.host/you/work.git";   # private
  };
  outputs = { multi-profile, work, ... }:
    multi-profile.lib.mkFlake {
      profiles = work.browserProfiles // {
        personal = { browser = "zen"; bookmarks = [ ... ]; };
      };
    };
}
```

Your main flake needs **only these two inputs** — Zen and the addon set are
bundled inside `multi-profile`.

### 3. A direnv per customer

In each customer directory, an `.envrc` (see `templates/main/.envrc`):

```sh
use flake .#acme
# or, if the dir is outside the flake repo:
# use flake "github:YOU/main#acme"
```

then just run:

```sh
web                 # short, same command in every customer direnv
# or the explicit name:
browser-acme
```

The profile is created under `./.direnv/browser-profiles/acme/` (already
gitignored by direnv), so logins and sessions persist across shells but stay
local to this directory.

> Rename the short command with `mkFlake { command = "..."; … }` (default `web`).

## Alternative: a self-contained per-project flake

If you don't want a central flake — you'd rather each project own its browser
and never reference the engine from its `.envrc` — use the `direnv` template:

```sh
cd my-project
nix flake init -t github:YOU/multi-profile#direnv
```

You get [`templates/direnv`](templates/direnv): a `flake.nix` that imports the
engine and defines a **single** profile for this project, plus an `.envrc` that
is just:

```sh
use flake
```

Because the flake defines one profile, the default devShell carries the short
`web` command, so a **bare `use flake`** is enough — the engine is referenced
only in this project's `flake.nix` inputs, never in the direnv. Then run `web`.
State still lives in `./.direnv/browser-profiles/<name>/`.

> Override the profile location with `MULTI_PROFILE_HOME=/some/path`.

## Profile options

Each profile value accepts:

| key                  | default            | meaning                                                             |
| -------------------- | ------------------ | ------------------------------------------------------------------- |
| `browser`            | `"zen"`            | `"zen"`, `"zen-twilight"`, `"firefox"`, a derivation, or `pkgs: drv`|
| `extensions`         | the 6 defaults     | list of `rycee.firefox-addons` names                                |
| `extraExtensions`    | `[]`               | extra addon derivations to add                                      |
| `bookmarks`          | `[]`               | tree of `{name;url;}` / `{name;children=[…];}`                      |
| `bookmarksFolderName`| profile name       | title of the managed bookmarks folder                              |
| `search`             | `null`             | declarative search engines (see below)                              |
| `foxyproxy`          | `null`             | FoxyProxy config as code (see below)                                |
| `pins`               | `[]`               | **Zen only** — essentials + pinned tabs as code (see below)         |
| `pinsForce`          | `false`            | make declared `pins` the source of truth (demote/remove others)     |
| `pinsForceAction`    | `"demote"`         | `"demote"` or `"remove"` undeclared pins when `pinsForce`           |
| `settings`           | `{}`               | extra `about:config` prefs (json values)                           |
| `policies`           | `{}`               | extra raw enterprise policies (recursively merged)                  |
| `prefs`              | `""`               | extra raw `mozilla.cfg` lines                                       |
| `profileDirName`     | profile name       | name of the local profile directory                                |
| `profileHome`        | `null`             | where the profile dir lives; `null` = direnv-local (`$PWD`)         |
| `icon`               | —                  | desktop-entry icon (home-manager module)                            |
| `desktopName`        | `Browser — <name>` | desktop-entry app name (home-manager module)                        |
| `desktopGenericName` | `Web Browser (<name>)` | desktop-entry generic name (home-manager module)                |

### Declarative search engines

Uses the `SearchEngines` policy (works on Firefox/Zen release ≥ 139):

```nix
search = {
  default = "DuckDuckGo";          # name of the default engine
  remove = [ "Bing" ];              # hide built-ins
  preventInstalls = true;           # block site-offered engines
  add = [
    { name = "Nix Packages";
      url = "https://search.nixos.org/packages?query={searchTerms}";
      alias = "@np";
      # optional: method, icon, suggestUrl, postData, encoding, description
    }
  ];
};
```

### FoxyProxy as code

Pushed into FoxyProxy via the `3rdparty` managed-storage policy, which makes it
**read-only** in the extension (true config-as-code). The shape mirrors
FoxyProxy's own export — when in doubt, configure it once in the UI, export, and
translate:

```nix
foxyproxy = {
  mode = "patterns";                # "patterns" | "disable" | a proxy title
  proxies = [
    { title = "Burp"; type = "http"; hostname = "127.0.0.1"; port = 8080;
      # optional: active, proxyDNS, username, password, color, pac, include, exclude
    }
  ];
  # extra = { ... };                # merged onto the managed object verbatim
};
```

### Essentials & pinned tabs as code (Zen)

Zen's **Essentials** (the icon grid, shown across workspaces) and **pinned
tabs** are, under the hood, entries in `zen-sessions.jsonlz4`. Declare them per
profile with `pins` — an `essential = true` entry becomes an Essential, anything
else a pinned tab:

```nix
pins = [
  { url = "https://teams.microsoft.com"; title = "Teams";   essential = true; }
  { url = "https://outlook.office.com";   title = "Outlook"; essential = true; }
  { url = "https://github.com/YOU/proj";  title = "Repo"; }       # pinned tab
  # optional per entry: container (userContextId), workspace (space UUID), id
];
pinsForce = true;          # declared pins are the source of truth
# pinsForceAction = "demote";  # "demote" (default) or "remove" undeclared pins
```

How it works and its limits:

- The launcher applies these to the profile's `zen-sessions.jsonlz4` **before
  starting Zen** (decompress → `jq` merge → recompress), so it works the same in
  a direnv or via a desktop entry. The merge only touches pinned/essential tabs
  and leaves the rest of your session intact.
- Zen writes that sessions file on first run, so pins appear from the **second
  launch onward**. Changing `pins` is picked up on the next launch — no rebuild
  needed.
- A non-essential **pinned tab** only renders inside a workspace, so pins
  declared without an explicit `workspace` are attached to the profile's default
  space automatically (essentials span all workspaces, so they need none).
- The merge is skipped while that profile's browser is already open (the file is
  locked); just relaunch. If anything goes wrong the previous session is
  restored and the browser still starts.
- **Zen only.** Firefox has no Essentials, and its pinned tabs use a different
  session schema; setting `pins` on a non-Zen profile logs a warning and is
  ignored. Tab *favicons* for pins are set in Zen for now (not declarative).

## System integration (home-manager): app entries + URL routing

The `homeModules.default` module installs each customer browser as a desktop
app **and** sets up a default "browser" that routes every link the system opens
to the right customer profile.

```nix
# home.nix
{ inputs, ... }:
{
  imports = [ inputs.multi-profile.homeModules.default ];

  programs.multiProfile = {
    enable = true;

    # Same data as mkFlake — merge your private work flake with public profiles.
    profiles = inputs.work.browserProfiles // {
      personal = {
        browser = "zen";
        desktopName = "Personal";        # custom app name in the launcher/menu
        # desktopGenericName = "Web Browser";
        # icon = "zen-beta";             # icon name or path
      };
    };

    defaultProfile = "personal";          # router fallback

    router.rules =
      inputs.work.browserRouterRules ++ [  # private rules + public ones
        { profile = "personal"; hosts = [ "github.com" "*.nixos.org" ]; }
      ];
  };
}
```

This gives you:

- `browser-<customer>` commands and **desktop entries** (with a distinct
  `StartupWMClass=browser-<customer>` for tiling WMs);
- a `browser-router` that parses each URL's host, matches it against
  `router.rules` (shell globs, first match wins, case-insensitive) and opens it
  in that customer's browser — falling back to `defaultProfile`;
- the router registered as the **default web browser** via `xdg.mimeApps`
  (`http`, `https`, `text/html`, …) and `$BROWSER`. Disable with
  `router.setAsDefaultBrowser = false`.

### Two profile locations, on purpose

| how you launch                         | profile directory                          |
| -------------------------------------- | ------------------------------------------ |
| from a direnv (`use flake`)            | `<project>/.direnv/browser-profiles/<name>` (local to that direnv) |
| desktop entry / router / plain shell   | `programs.multiProfile.profileHome/<name>` (stable, default `~/.local/share/multi-profile`) |

So a link clicked anywhere on the system always lands in the *canonical*
customer profile, while a project direnv keeps its own persistent, sandboxed
copy (sessions and logins survive, stored next to that `.direnv`).

The direnv-mode launcher resolves its profile root in this order:
`MULTI_PROFILE_HOME` → `$DIRENV_LAYOUT_DIR/browser-profiles` →
`<DIRENV_DIR>/.direnv/browser-profiles` → `$PWD/.browser-profiles` (no direnv).
The system-mode launcher always uses `profileHome` (overridable only by
`MULTI_PROFILE_HOME`), so each profile keeps a separate state folder.

> Routing matches **host suffixes**: `*.acme.com` matches `teams.acme.com` but
> not `acme.com` — list both if you need the bare domain.

## Flake outputs (`multi-profile.lib`)

- `mkFlake { profiles; systems? config? overlays? nixpkgs? }` → `{ packages, apps, devShells }`.
  - `packages.<system>.<name>` / `apps.<system>.<name>` — the launchers.
  - `devShells.<system>.<name>` — shell with that launcher (for `use flake .#name`).
  - `devShells.<system>.default` — shell with every launcher (plus the short
    `command`/`web` alias when the flake defines a single profile).
- `mkProfile { pkgs; zen; addons; } name profileDef` — lower-level builder
  returning `{ browser; launcher; }`.
- `defaultExtensions` — the default extension name list.

And `homeModules.default` — the home-manager module described above.

## Notes

- **Container tabs** are enabled (`privacy.userContext.*`). Note that with
  separate profiles per customer you get stronger isolation than containers
  within one profile; use containers *within* a customer profile if you also
  juggle several identities for the same customer.
- **Wappalyzer is unfree**, so `mkFlake` sets `allowUnfree = true` by default.
  Override via the `config` argument.
- Zen comes from the community flake
  [`0xc000022070/zen-browser-flake`](https://github.com/0xc000022070/zen-browser-flake).
