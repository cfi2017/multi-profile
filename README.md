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
- Policies (extensions, bookmarks, search, foxyproxy, certs) are applied via
  `wrapFirefox`'s `extraPolicies` for **both** Firefox and Zen: `wrapFirefox`
  regenerates the browser's `distribution/policies.json`, and that copy is the
  one the running browser reads — even for Zen, whose unwrapped package ships
  its own `distribution/`. (Baking policies into the Zen package via its
  `policies` arg looks right but is silently shadowed by `wrapFirefox`.) Prefs
  differ: Firefox reads `wrapFirefox`'s `mozilla.cfg`, while Zen doesn't
  reliably honour it for app-default overrides (e.g. the welcome screen), so
  Zen prefs are delivered through a managed `user.js` in the profile.
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
| `transparency`       | `false`            | **Zen only** — transparent UI (Linux needs a blur-capable compositor) |
| `transparentContent` | `false`            | **Zen only** — also make web page backgrounds transparent            |
| `accentColor`        | `null`             | **Zen only** — UI accent as a hex string, e.g. `"#8ab4f8"`           |
| `search`             | `null`             | declarative search engines (see below)                              |
| `foxyproxy`          | `null`             | FoxyProxy config as code (see below)                                |
| `certificates`       | `[]`               | CA certs (PEM/DER) to trust via `Certificates.Install` (see below)  |
| `importEnterpriseRoots` | `false`         | also trust the OS / platform enterprise trust store                 |
| `securityDevices`    | `{}`               | PKCS#11 modules `{ label = "…/module.so"; }`, added at launch (see below) |
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

### Appearance: transparency & accent color (Zen)

Two friendly options make a profile visually distinct — handy when several
customer browsers are open at once:

```nix
transparency       = true;        # transparent browser UI
transparentContent = true;        # transparent web page backgrounds too
accentColor        = "#8ab4f8";   # tint the UI with a per-customer color
```

- `transparency` sets `zen.widget.linux.transparency` (Linux) and
  `zen.theme.acrylic-elements` (Windows/macOS acrylic blur). On Linux you need a
  compositor that does window blur — **KDE** (optionally with
  `kwin-effects-forceblur`) or **Hyprland**; GNOME has no proper support.
- `transparentContent` sets `browser.tabs.allow_transparent_browser`, tinting
  web page backgrounds with your theme color so the blur shows through the page
  too. Off by default — it can break sites that assume an opaque background.
- `accentColor` sets `zen.theme.accent-color` (any hex string). It's re-written
  to `user.js` on every launch, so it survives Zen's occasional
  reset-accent-on-startup behaviour.

Both are Zen-only; on Firefox they're harmless no-op prefs. They're just
shortcuts — anything you'd rather set by hand still works through `settings`.

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

### CA certificates & PKCS#11 security devices

Both work on Firefox **and Zen** and are scoped to that profile. They're
delivered differently for a good reason (see the box below), but the config is
uniform.

**CA certificates.** `certificates` is a list of PEM or DER files trusted as
roots via the [`Certificates.Install`][cert] enterprise policy. A local path is
copied into the store; a store path or derivation is copied into a
*reference-free* store file (so a cert taken from a package can't drag that
package's closure — see the box); a plain absolute string (a runtime system
path) is referenced as-is. Set `importEnterpriseRoots` to also trust the
platform trust store (system NSS/p11-kit on Linux; the OS keychain on
macOS/Windows):

```nix
certificates = [
  ./corp-root.pem                             # copied into the store on eval
  "/etc/ssl/certs/internal-ca.der"            # runtime system path, as-is
  "${pkgs.cacert.unbundled}/etc/ssl/certs/…"  # copied out of the package
];
importEnterpriseRoots = true;                 # also trust the OS trust store
```

Certs are baked in at build time, so trust is reproducible and needs no
first-run step.

**PKCS#11 security devices** (smartcards, YubiKeys, HSMs, soft-HSM). Give
`securityDevices` an attrset of `label = path-to-module`; each is registered in
the profile's NSS db **at launch** (via `modutil`, the same before-start hook as
pins):

```nix
securityDevices = {
  "OpenSC"    = "${pkgs.opensc}/lib/opensc-pkcs11.so";
  "YubiKey"   = "${pkgs.yubico-piv-tool}/lib/libykcs11.so";
  # "SoftHSM" = "${pkgs.softhsm}/lib/softhsm/libsofthsm2.so";  # needs SOFTHSM2_CONF
};
```

Registration is idempotent and re-applied every launch, so changing the set is
picked up on the next start (no rebuild). If a module can't be loaded (missing
supporting binaries or a daemon — e.g. `pcscd` for physical smartcards — or a
module like SoftHSM that needs env config), a warning is logged and the browser
still starts; add the module's package / daemon to your environment to fix it.

> **Why the split?** Both would naturally be Firefox [enterprise policies][pol].
> But `wrapFirefox` forbids a compiler (`stdenv.cc`) anywhere in the wrapped
> browser's closure (`disallowedRequisites`), and a policy's store paths become
> part of that closure. A PKCS#11 module's runtime closure often pulls in a
> compiler, which would fail the build — so devices are applied at launch
> instead, keeping the module path in the *launcher's* closure, not the
> browser's. Cert files are copied reference-free for the same safety, so they
> can stay a policy.
>
> Need something the options don't cover? Anything under `policies` is
> recursively merged on top, so you can hand-write the raw
> [`Certificates`][cert] / [`SecurityDevices`][dev] policy and it wins (mind the
> closure caveat for device paths).

[pol]: https://mozilla.github.io/policy-templates/
[cert]: https://mozilla.github.io/policy-templates/#certificates
[dev]: https://mozilla.github.io/policy-templates/#securitydevices

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
- On a brand-new profile the launcher **seeds** a minimal sessions file if Zen
  hasn't written one yet, so pins/essentials appear from the **first launch**.
  Changing `pins` is picked up on the next launch — no rebuild needed.
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
