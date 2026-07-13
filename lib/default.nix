{ lib }:

let
  # Firefox application id; the rycee firefox-addons store xpis under
  #   $out/share/mozilla/extensions/<firefoxAppId>/<addonId>.xpi
  firefoxAppId = "{ec8030f7-c20a-464f-9b0e-13a3a9e97384}";

  # Extensions every profile gets unless overridden. Names are attrs in
  # nur.repos.rycee.firefox-addons.
  defaultExtensions = [
    "ublock-origin"
    "bitwarden"
    "foxyproxy-standard"
    "wappalyzer"
    "dearrow"
    "sponsorblock"
  ];

  # Deterministic UUID (v4 shape) from a seed string, so a pin's identity is
  # stable across rebuilds (Zen keys tabs by `zenSyncId`; a changing id would
  # duplicate the pin on every launch).
  mkUuid = seed:
    let
      h = builtins.hashString "sha256" seed;
      s = i: len: builtins.substring i len h;
    in
    "${s 0 8}-${s 8 4}-4${s 13 3}-8${s 17 3}-${s 20 12}";

  # Browser spec strings that resolve to a Zen build (essentials/pins are a
  # Zen-only concept, stored in zen-sessions.jsonlz4).
  zenBrowsers = [ "zen" "zen-beta" "zen-twilight" ];

  # One declared pin -> a Zen sessions `.tabs` entry. `p` carries an injected
  # `_id` (uuid) and `_index` (order). Shapes mirror the zen-browser-flake so
  # Zen accepts the merged file. An "essential" is a pin with zenEssential.
  mkPinTab = p: {
    pinned = true;
    hidden = false;
    zenWorkspace = if (p.workspace or null) == null then null else "{${p.workspace}}";
    zenSyncId = "{${p._id}}";
    zenEssential = p.essential or false;
    zenDefaultUserContextId = "true";
    zenPinnedIcon = null;
    zenIsEmpty = false;
    zenHasStaticIcon = false;
    zenGlanceId = null;
    zenIsGlance = false;
    searchMode = null;
    userContextId = if (p.container or null) == null then 0 else p.container;
    attributes = { };
    index = p._index;
    lastAccessed = 0;
    groupId = null;
    # a custom title (differs from the url) shows as the pinned tab's label
    zenStaticLabel = if (p ? title && p.title != p.url) then p.title else null;
    entries = [{
      url = p.url;
      title = p.title or p.url;
      charset = "UTF-8";
      ID = 0;
      persist = true;
    }];
  };

  # Resolve a `browser` spec into an *unwrapped* firefox-family derivation
  # (something `wrapFirefox` can wrap).
  resolveUnwrapped = { pkgs, zen, browser }:
    if lib.isDerivation browser then browser
    else if lib.isFunction browser then browser pkgs
    else if browser == "firefox" then pkgs.firefox-unwrapped
    else if browser == "firefox-esr" then (pkgs.firefox-esr-unwrapped or pkgs.firefox-unwrapped)
    else if browser == "zen" || browser == "zen-beta" then zen.beta-unwrapped
    else if browser == "zen-twilight" then zen.twilight-unwrapped
    else throw "multi-profile: unknown browser '${toString browser}' (use \"zen\", \"zen-twilight\", \"firefox\", a derivation, or a function pkgs -> derivation)";

  # extension derivation -> ExtensionSettings policy entry
  extensionPolicyEntry = ext: {
    name = ext.addonId;
    value = {
      installation_mode = "force_installed";
      install_url = "file://${ext}/share/mozilla/extensions/${firefoxAppId}/${ext.addonId}.xpi";
    };
  };

  # Recursively turn a friendly bookmark tree into the ManagedBookmarks shape.
  # Input node:  { name; url; }              -> a bookmark
  #              { name; children = [ ... ]; } -> a folder
  # `ctx` is a human label (e.g. "profile 'acme'") used only in error messages.
  toManaged = ctx: nodes:
    map
      (n:
        if !(n ? name)
        then throw "multi-profile: a bookmark node in ${ctx} is missing `name` (bookmarks use `name`, not `title` like pins/search): ${builtins.toJSON n}"
        else if n ? children
        then { inherit (n) name; children = toManaged ctx n.children; }
        else if n ? url
        then { inherit (n) name; url = n.url; }
        else throw "multi-profile: bookmark '${n.name}' in ${ctx} needs either `url` (a bookmark) or `children` (a folder)")
      nodes;

  # attrset of about:config prefs -> mozilla.cfg lines (Firefox)
  settingsToPrefs = s:
    lib.concatStringsSep "\n"
      (lib.mapAttrsToList (k: v: ''defaultPref("${k}", ${builtins.toJSON v});'') s);

  # attrset of about:config prefs -> user.js lines (Zen). Zen doesn't reliably
  # honour wrapFirefox's mozilla.cfg for app-default overrides (e.g. the welcome
  # screen), so prefs are delivered via the profile's user.js instead.
  prefsToUserJs = s:
    lib.concatStringsSep "\n"
      (lib.mapAttrsToList (k: v: ''user_pref("${k}", ${builtins.toJSON v});'') s);

  foxyproxyId = "foxyproxy@eric.h.jung";

  # friendly `search` attrset -> SearchEngines policy
  #   { default ? null; remove ? []; preventInstalls ? false;
  #     add = [ { name; url; alias?; method?; icon?; suggestUrl?; postData?;
  #               encoding?; description?; } ]; }
  mkSearchPolicy = s:
    let
      engineEntry = e:
        { Name = e.name; URLTemplate = e.url; }
        // lib.optionalAttrs (e ? alias) { Alias = e.alias; }
        // lib.optionalAttrs (e ? method) { Method = e.method; }
        // lib.optionalAttrs (e ? icon) { IconURL = e.icon; }
        // lib.optionalAttrs (e ? suggestUrl) { SuggestURLTemplate = e.suggestUrl; }
        // lib.optionalAttrs (e ? postData) { PostData = e.postData; }
        // lib.optionalAttrs (e ? encoding) { Encoding = e.encoding; }
        // lib.optionalAttrs (e ? description) { Description = e.description; };
    in
    lib.optionalAttrs (s.add or [ ] != [ ]) { Add = map engineEntry s.add; }
    // lib.optionalAttrs (s.default or null != null) { Default = s.default; }
    // lib.optionalAttrs (s.remove or [ ] != [ ]) { Remove = s.remove; }
    // lib.optionalAttrs (s.preventInstalls or false) { PreventInstalls = true; };

  # friendly `foxyproxy` attrset -> FoxyProxy managed-storage object.
  # The format mirrors FoxyProxy's own export; managed storage is read-only.
  #   { mode ? "patterns"; proxies = [ { title; type ? "http"; hostname; port;
  #       active ? true; proxyDNS ? true; username?; password?; color?;
  #       pac?; cc?; city?; include ? []; exclude ? []; extra ? {}; } ];
  #     extra ? {}; }
  mkFoxyProxy = fp:
    let
      proxyEntry = p: {
        active = p.active or true;
        title = p.title or "";
        type = p.type or "http";
        hostname = p.hostname or "";
        port = toString (p.port or "");
        username = p.username or "";
        password = p.password or "";
        cc = p.cc or "";
        city = p.city or "";
        color = p.color or "#66ccff";
        pac = p.pac or "";
        proxyDNS = p.proxyDNS or true;
        include = p.include or [ ];
        exclude = p.exclude or [ ];
      } // (p.extra or { });
    in
    {
      mode = fp.mode or "patterns";
      sync = false;
      data = map proxyEntry (fp.proxies or [ ]);
    } // (fp.extra or { });
in
rec {
  inherit defaultExtensions;

  # Build a single profile.
  #
  # `mkProfile { pkgs; zen; addons; } name profileDef` -> {
  #   browser  = wrapped firefox/zen derivation (extensions + bookmarks baked in);
  #   launcher = a `name`d script that runs the browser against a direnv-local
  #              profile directory;
  #   package  = launcher (alias);
  # }
  mkProfile =
    { pkgs
    , zen # zen-browser flake `packages.<system>`
    , addons # nur.repos.rycee.firefox-addons for this system
    }:
    name:
    { browser ? "zen"
      # list of rycee firefox-addons names, or extension derivations
    , extensions ? defaultExtensions
      # extra extension derivations to add on top of `extensions`
    , extraExtensions ? [ ]
      # bookmark tree (see toManaged); rendered as a read-only managed folder
    , bookmarks ? [ ]
    , bookmarksFolderName ? name
      # extra about:config prefs (attrset, json-serialisable values)
    , settings ? { }
      # Zen only: make the browser UI transparent. On Linux this needs a
      # blur-capable compositor (KDE/Hyprland; GNOME has no proper support);
      # on Windows/macOS it enables the acrylic blur behind UI elements.
    , transparency ? false
      # Zen only: also make web *content* transparent — page backgrounds are
      # tinted with the theme color so the compositor blur shows through the
      # page too. Off by default because it can break sites that assume an
      # opaque background.
    , transparentContent ? false
      # Zen only: UI accent color as a hex string (e.g. "#8ab4f8"). Handy for
      # telling customer browsers apart at a glance. Re-applied every launch,
      # so it survives Zen's occasional accent-color reset on startup.
    , accentColor ? null
      # declarative search engines (see mkSearchPolicy)
    , search ? null
      # FoxyProxy config as code (see mkFoxyProxy)
    , foxyproxy ? null
      # CA certificates to trust in this profile, as a list of PEM/DER files.
      # A local path (e.g. ./corp-root.pem) is copied into the store; a store
      # path, derivation, or absolute string path (e.g. "/etc/ssl/…") is used
      # as-is. Rendered into the `Certificates.Install` enterprise policy, so
      # the browser trusts them as roots without any manual import.
    , certificates ? [ ]
      # Also trust the OS / platform enterprise trust store
      # (Certificates.ImportEnterpriseRoots): on Linux, certs from the system
      # NSS/p11-kit trust; on macOS/Windows, the OS keychain/cert store.
    , importEnterpriseRoots ? false
      # PKCS#11 security devices (smartcards, HSMs, YubiKeys, soft-HSM …), as an
      # attrset of `<device label> = <path to the module .so/.dylib>`. e.g.
      #   { "OpenSC" = "${pkgs.opensc}/lib/opensc-pkcs11.so"; }
      # Registered in the profile's NSS db at launch via `modutil` (NOT the
      # enterprise policy): a module's runtime closure often pulls in a compiler,
      # and wrapFirefox forbids `stdenv.cc` in the wrapped browser's closure
      # (`disallowedRequisites`). Delivering at launch keeps the module path in
      # the launcher's closure, not the browser's — see seedDevices.
    , securityDevices ? { }
      # Zen only: essentials + pinned tabs as code. Ordered list of
      #   { url; title ? url; essential ? false; container ? null;
      #     workspace ? null; id ? <derived>; }
      # `essential = true` -> a Zen "Essential" (shown across workspaces);
      # otherwise a pinned tab. Applied to zen-sessions.jsonlz4 at launch.
    , pins ? [ ]
      # When true, undeclared pinned/essential tabs are demoted (default) or
      # removed on launch, so the declared pins are the source of truth.
    , pinsForce ? false
    , pinsForceAction ? "demote" # "demote" | "remove"
      # extra raw policies, recursively merged over the defaults
    , policies ? { }
      # extra raw mozilla.cfg lines
    , prefs ? ""
      # name of the local profile dir
    , profileDirName ? name
      # where the runtime profile dir lives. null => direnv-local
      # ($PWD/.browser-profiles); set to a stable path for system/home-manager
      # use. $MULTI_PROFILE_HOME always overrides at runtime.
    , profileHome ? null
    , ...
    }:
    let
      unwrappedBase = resolveUnwrapped { inherit pkgs zen browser; };
      isZen = lib.isString browser && lib.elem browser zenBrowsers;

      resolvedExts =
        (map
          (e:
            if lib.isString e
            then (addons.${e} or (throw "multi-profile: unknown extension '${e}' (not in nur.repos.rycee.firefox-addons)"))
            else e)
          extensions)
        ++ extraExtensions;

      extensionSettings = lib.listToAttrs (map extensionPolicyEntry resolvedExts);

      managedBookmarks =
        lib.optionals (bookmarks != [ ])
          ([{ toplevel_name = bookmarksFolderName; }] ++ toManaged "profile '${name}'" bookmarks);

      # CA certs -> absolute path strings for Certificates.Install.
      #
      # These end up embedded in policies.json, which becomes a *runtime
      # reference* of the wrapped browser — and wrapFirefox bans `stdenv.cc`
      # from that closure (disallowedRequisites). A bare cert file has no store
      # references, but one taken from a package output might, so copy each
      # store-backed cert into a reference-free store file (a plain `cp`, which
      # also handles binary DER). Plain absolute strings (e.g. "/etc/ssl/…") are
      # runtime system paths — not store refs — so pass them through untouched.
      storifyCert = i: c:
        if lib.isString c && !(lib.hasPrefix builtins.storeDir c)
        then c
        else pkgs.runCommand "multi-profile-cert-${name}-${toString i}" { } ''
          cp ${c} "$out"
        '';
      certInstall = lib.imap0 (i: c: toString (storifyCert i c)) certificates;

      basePrefs = {
        # container tabs (multi-account containers / "Open in container")
        "privacy.userContext.enabled" = true;
        "privacy.userContext.ui.enabled" = true;
        # keep startup quiet & predictable
        "browser.aboutConfig.showWarning" = false;
        "browser.shell.checkDefaultBrowser" = false;
        "datareporting.policy.dataSubmissionEnabled" = false;
        "extensions.autoDisableScopes" = 0;
        # skip the first-run / onboarding flow on a fresh profile
        "zen.welcome-screen.seen" = true; # Zen's setup screen ("a calmer internet")
        "browser.aboutwelcome.enabled" = false; # Firefox about:welcome
        "browser.startup.homepage_override.mstone" = "ignore"; # no first-run/whatsnew page
        "startup.homepage_welcome_url" = "";
        "startup.homepage_welcome_url.additional" = "";
        "browser.messaging-system.whatsNewPanel.enabled" = false;
        "datareporting.policy.firstRunURL" = "";
        "toolkit.telemetry.reportingpolicy.firstRun" = false;
      };

      allPolicies = lib.recursiveUpdate
        ({
          DisableAppUpdate = true;
          DisableTelemetry = true;
          # skip first-run onboarding: no welcome page, no post-update page,
          # no "make me default" nag.
          OverrideFirstRunPage = "";
          OverridePostUpdatePage = "";
          DontCheckDefaultBrowser = true;
          ExtensionSettings = extensionSettings;
        }
        // lib.optionalAttrs (managedBookmarks != [ ]) {
          ManagedBookmarks = managedBookmarks;
        }
        // lib.optionalAttrs (search != null) {
          SearchEngines = mkSearchPolicy search;
        }
        // lib.optionalAttrs (foxyproxy != null) {
          "3rdparty".Extensions.${foxyproxyId} = mkFoxyProxy foxyproxy;
        }
        // lib.optionalAttrs (importEnterpriseRoots || certInstall != [ ]) {
          Certificates =
            lib.optionalAttrs importEnterpriseRoots { ImportEnterpriseRoots = true; }
            // lib.optionalAttrs (certInstall != [ ]) { Install = certInstall; };
        })
        policies;

      # Zen appearance prefs derived from the friendly `transparency` /
      # `accentColor` options. Delivered like any other pref (user.js on Zen,
      # mozilla.cfg on Firefox, where they're harmless no-ops). The user's
      # explicit `settings` still win over these.
      themePrefs =
        lib.optionalAttrs transparency {
          "zen.widget.linux.transparency" = true; # Linux: transparent chrome
          "zen.theme.acrylic-elements" = true; # Windows/macOS: acrylic blur
        }
        // lib.optionalAttrs transparentContent {
          "browser.tabs.allow_transparent_browser" = true; # transparent web content
        }
        // lib.optionalAttrs (accentColor != null) {
          "zen.theme.accent-color" = accentColor;
        };

      allPrefs = basePrefs // themePrefs // settings;

      # Policies go through wrapFirefox's `extraPolicies` for BOTH browsers.
      #
      # wrapFirefox regenerates the browser's `lib/<app>/distribution/` dir and
      # writes a fresh policies.json there from `extraPolicies` — and *that* is
      # the file the running browser reads, even for Zen (whose unwrapped
      # package ships its own distribution/). Baking policies into the unwrapped
      # package via its `policies` arg is therefore shadowed by wrapFirefox and
      # has NO effect once wrapped, which silently dropped bookmarks,
      # extensions, search and foxyproxy on Zen. So deliver them here.
      #
      # Prefs still differ: Firefox reads wrapFirefox's mozilla.cfg; Zen doesn't
      # reliably honour it for app-default overrides (e.g. the welcome screen),
      # so Zen prefs are delivered through the profile's user.js (see seedUserJs).
      wrapped = pkgs.wrapFirefox unwrappedBase {
        # distinct window class per profile (handy for tiling WMs / identifying
        # which customer a window belongs to)
        wmClass = "browser-${name}";
        extraPolicies = allPolicies;
        extraPrefs = if isZen then "" else (settingsToPrefs allPrefs + "\n" + prefs);
      };

      # How to resolve the runtime profile directory at launch.
      #
      # profileHome == null  -> direnv mode: keep state next to the .direnv of
      #   the calling project, so session persistence is local to that direnv.
      # profileHome != null  -> system mode: a fixed root, one folder per
      #   profile, isolating customer state.
      #
      # $MULTI_PROFILE_HOME always wins.
      resolveHome =
        if profileHome == null then ''
          if [ -n "''${MULTI_PROFILE_HOME:-}" ]; then
            profile_home="$MULTI_PROFILE_HOME"
          elif [ -n "''${DIRENV_LAYOUT_DIR:-}" ]; then
            # direnv's per-.envrc layout dir (usually <project>/.direnv)
            profile_home="$DIRENV_LAYOUT_DIR/browser-profiles"
          elif [ -n "''${DIRENV_DIR:-}" ]; then
            # DIRENV_DIR is the .envrc dir prefixed with '-'
            profile_home="''${DIRENV_DIR#-}/.direnv/browser-profiles"
          else
            profile_home="$PWD/.browser-profiles"
          fi
        '' else ''
          profile_home="''${MULTI_PROFILE_HOME:-${profileHome}}"
        '';

      # ---- essentials + pinned tabs (Zen only) ----------------------------
      pinsEnabled = pins != [ ] && isZen;

      # inject a stable id + order into each declared pin
      indexedPins = lib.imap0
        (i: p: p // {
          _index = i;
          _id = p.id or (mkUuid "${toString p.url}|${p.title or p.url}|${lib.boolToString (p.essential or false)}|${toString (p.workspace or "")}");
        })
        pins;

      pinsJsonFile = pkgs.writeText "zen-declared-pins-${name}.json"
        (builtins.toJSON (map mkPinTab indexedPins));

      # jq merge: update declared pins in place, append new ones, optionally
      # reconcile undeclared pins, then order by index. Operates on the `.tabs`
      # array of a decompressed zen-sessions.jsonlz4.
      pinsForceSnippet =
        if pinsForce && pinsForceAction == "remove" then ''
          | .tabs = [ .tabs[]
              | if (.pinned == true or .zenEssential == true)
                then select(.zenSyncId as $id | $dpIds | index($id) != null)
                else . end ]''
        else if pinsForce then ''
          | .tabs = [ .tabs[]
              | if ((.pinned == true or .zenEssential == true) and (.zenSyncId as $id | $dpIds | index($id) | not))
                then (. * { pinned: false, zenEssential: false, groupId: null })
                else . end ]''
        else "";

      pinsFilterFile = pkgs.writeText "zen-pins-merge-${name}.jq" ''
        # A non-essential pinned tab only renders inside a workspace, and the
        # workspace UUID is generated per-profile by Zen — so pins declared
        # without an explicit `workspace` are attached here to the session's
        # default (or first) space. Essentials span all workspaces, so they
        # keep zenWorkspace = null.
        (.spaces // []) as $spaces
        | (($spaces | map(select(.default == true)) | .[0].uuid) // ($spaces[0].uuid // null)) as $defaultWs
        | ($declaredPins[0] | map(
            if (.zenEssential != true) and (.zenWorkspace == null)
            then (.zenWorkspace = $defaultWs)
            else . end)) as $pins
        | .tabs = (.tabs // [])
        | ([.tabs[].zenSyncId]) as $etIds
        | ([$pins[].zenSyncId]) as $dpIds
        | .tabs = [ .tabs[]
            | . as $e
            | ($pins | map(select(.zenSyncId == $e.zenSyncId)) | .[0] // null) as $o
            | if $o != null
              then $e * { pinned: $o.pinned, zenEssential: $o.zenEssential, zenWorkspace: $o.zenWorkspace, userContextId: $o.userContextId, index: $o.index, entries: $o.entries, groupId: $o.groupId, zenStaticLabel: $o.zenStaticLabel }
              else . end ]
        | .tabs += [ $pins[] | select(.zenSyncId as $id | $etIds | index($id) | not) ]
        ${pinsForceSnippet}
        | .tabs = (.tabs | sort_by(.index // 0))
      '';

      # Runs before exec (Zen closed for this profile). On a fresh profile Zen
      # hasn't written the sessions file yet, so we SEED a minimal valid one and
      # merge into it — that way declared essentials/pins show from the FIRST
      # launch instead of the second. The merge is idempotent and preserves the
      # rest of the session; it never blocks the browser from starting.
      applyPins = lib.optionalString pinsEnabled ''
        sessions="$dir/zen-sessions.jsonlz4"
        # only touch the session while this profile is closed (Zen holds the
        # file in memory and rewrites it on exit while it's live).
        if [ ! -e "$dir/.parentlock" ] && [ ! -e "$dir/lock" ]; then
          if [ ! -f "$sessions" ]; then
            # seed an empty-but-valid session so the merge has something to
            # write essentials/pins into on a brand-new profile.
            printf '%s' '{"spaces":[],"tabs":[],"folders":[],"groups":[]}' > "$dir/.zen-seed.json"
            mozlz4a "$dir/.zen-seed.json" "$sessions" || true
            rm -f "$dir/.zen-seed.json"
          fi
          if [ -f "$sessions" ]; then
            _in="$(mktemp)"; _out="$(mktemp)"
            cp -f "$sessions" "$sessions.bak" || true
            if mozlz4a -d "$sessions" "$_in" \
              && jq --slurpfile declaredPins ${pinsJsonFile} -f ${pinsFilterFile} "$_in" > "$_out" \
              && [ -s "$_out" ] \
              && mozlz4a "$_out" "$sessions"; then
              rm -f "$sessions.bak"
            else
              echo "multi-profile: failed to apply pins, restoring session" >&2
              [ -f "$sessions.bak" ] && mv -f "$sessions.bak" "$sessions"
            fi
            rm -f "$_in" "$_out"
          fi
        fi
      '';

      # Zen reads none of wrapFirefox's mozilla.cfg, so ALL prefs (container
      # tabs, homepage, first-run/onboarding skip, default-browser check off,
      # plus the user's `settings`) are delivered via the profile's user.js.
      # It's applied at pref-init before any chrome runs, and rewritten each
      # launch (user.js is ours on a managed profile).
      zenUserJs = pkgs.writeText "multi-profile-user-${name}.js" (
        "// Managed by multi-profile — regenerated on each launch, do not edit.\n"
        + prefsToUserJs allPrefs
        + "\n"
      );
      seedUserJs = lib.optionalString isZen ''
        cp -f ${zenUserJs} "$dir/user.js"
      '';

      # ---- PKCS#11 security devices (Firefox + Zen) -----------------------
      # Registered into the profile's NSS db (secmod.db/pkcs11.db) with modutil
      # rather than via the enterprise policy, so the module's store path (and
      # its compiler-tainted closure) stays out of the wrapped browser — see the
      # `securityDevices` param note. Delete-then-add makes it declarative and
      # idempotent (picks up a changed path); runs each launch, never fatal.
      devicesEnabled = securityDevices != { };
      seedDevices = lib.optionalString devicesEnabled ''
        # skip while the profile is live (NSS db locked by the running browser)
        if [ ! -e "$dir/.parentlock" ] && [ ! -e "$dir/lock" ]; then
          # ensure an NSS db exists (fresh profile has none until first run)
          [ -f "$dir/cert9.db" ] || certutil -d "sql:$dir" -N --empty-password >/dev/null 2>&1 || true
          ${lib.concatStringsSep "\n          " (lib.mapAttrsToList (label: mod: ''
            modutil -dbdir "sql:$dir" -force -delete ${lib.escapeShellArg label} >/dev/null 2>&1 || true
            modutil -dbdir "sql:$dir" -force -add ${lib.escapeShellArg label} -libfile ${lib.escapeShellArg (toString mod)} >/dev/null 2>&1 \
              || echo "multi-profile: failed to register security device ${lib.escapeShellArg label}" >&2'')
            securityDevices)}
        fi
      '';

      launcher = pkgs.writeShellApplication {
        name = "browser-${name}";
        runtimeInputs =
          lib.optionals pinsEnabled [ pkgs.jq pkgs.mozlz4a ]
          ++ lib.optionals devicesEnabled [ pkgs.nss.tools ];
        text = ''
          ${resolveHome}
          dir="$profile_home/${profileDirName}"
          mkdir -p "$dir"
          ${seedUserJs}
          ${seedDevices}
          ${applyPins}
          # --no-remote + a dedicated profile lets every customer browser run
          # concurrently, fully isolated from each other and your personal one.
          exec ${lib.getExe wrapped} --no-remote --profile "$dir" "$@"
        '';
      };
    in
    lib.warnIf (pins != [ ] && !isZen)
      "multi-profile: profile '${name}' sets `pins` but browser is not Zen; essentials/pinned tabs are Zen-only and will be ignored."
      {
        inherit name launcher;
        browser = wrapped;
        package = launcher;
      };
}
