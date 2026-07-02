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

  # attrset of about:config prefs -> mozilla.cfg lines
  settingsToPrefs = s:
    lib.concatStringsSep "\n"
      (lib.mapAttrsToList (k: v: ''defaultPref("${k}", ${builtins.toJSON v});'') s);

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
      # declarative search engines (see mkSearchPolicy)
    , search ? null
      # FoxyProxy config as code (see mkFoxyProxy)
    , foxyproxy ? null
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
      unwrapped = resolveUnwrapped { inherit pkgs zen browser; };

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

      basePrefs = {
        # container tabs (multi-account containers / "Open in container")
        "privacy.userContext.enabled" = true;
        "privacy.userContext.ui.enabled" = true;
        # keep startup quiet & predictable
        "browser.aboutConfig.showWarning" = false;
        "browser.shell.checkDefaultBrowser" = false;
        "datareporting.policy.dataSubmissionEnabled" = false;
        "extensions.autoDisableScopes" = 0;
        # skip the first-run / onboarding flow on a fresh profile.
        # NB: Zen ships `pref("zen.welcome-screen.seen", false)` as an app
        # default, and a mozilla.cfg defaultPref does not reliably override it,
        # so the welcome screen ("a calmer internet") is instead suppressed by
        # seeding a user-branch pref via user.js — see `seedUserJs` below.
        "browser.aboutwelcome.enabled" = false; # Firefox about:welcome
        "browser.startup.homepage_override.mstone" = "ignore"; # no first-run/whatsnew page
        "startup.homepage_welcome_url" = "";
        "startup.homepage_welcome_url.additional" = "";
        "browser.messaging-system.whatsNewPanel.enabled" = false;
        "datareporting.policy.firstRunURL" = "";
        "toolkit.telemetry.reportingpolicy.firstRun" = false;
      };

      wrapped = pkgs.wrapFirefox unwrapped {
        # distinct window class per profile (handy for tiling WMs / identifying
        # which customer a window belongs to)
        wmClass = "browser-${name}";
        extraPolicies = lib.recursiveUpdate
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
          })
          policies;
        # Belt-and-suspenders lock (the authoritative fix is the user.js seed in
        # the launcher; this only helps where autoconfig is honored).
        extraPrefs =
          settingsToPrefs (basePrefs // settings)
          + "\n" + ''lockPref("zen.welcome-screen.seen", true);''
          + "\n" + prefs;
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
      isZen = lib.isString browser && lib.elem browser zenBrowsers;
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
        ($declaredPins[0]) as $pins
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

      # Runs before exec (Zen closed for this profile). Zen writes the sessions
      # file on first run, so pins land from the *second* launch onward; the
      # merge is idempotent and preserves the rest of the session. Never blocks
      # the browser from starting.
      applyPins = lib.optionalString pinsEnabled ''
        sessions="$dir/zen-sessions.jsonlz4"
        # skip while this profile is live (file is locked in memory)
        if [ -f "$sessions" ] && [ ! -e "$dir/.parentlock" ] && [ ! -e "$dir/lock" ]; then
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
      '';

      # Force Zen's first-run welcome ("a calmer internet") to be treated as
      # already seen. A defaultPref/lockPref in mozilla.cfg is read back as
      # false by Zen's startup check, so we pin it on the *user* branch via
      # user.js — the same mechanism Zen's own test profiles use. Rewritten each
      # launch (user.js is ours on a managed profile), applied at pref init
      # before any chrome runs.
      seedUserJs = lib.optionalString isZen ''
        {
          echo "// Managed by multi-profile — regenerated on each launch, do not edit."
          echo 'user_pref("zen.welcome-screen.seen", true);'
        } > "$dir/user.js"
      '';

      launcher = pkgs.writeShellApplication {
        name = "browser-${name}";
        runtimeInputs = lib.optionals pinsEnabled [ pkgs.jq pkgs.mozlz4a ];
        text = ''
          ${resolveHome}
          dir="$profile_home/${profileDirName}"
          mkdir -p "$dir"
          ${seedUserJs}
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
