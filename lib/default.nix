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
  toManaged = nodes:
    map
      (n:
        if n ? children
        then { inherit (n) name; children = toManaged n.children; }
        else { inherit (n) name; url = n.url; })
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
          ([{ toplevel_name = bookmarksFolderName; }] ++ toManaged bookmarks);

      basePrefs = {
        # container tabs (multi-account containers / "Open in container")
        "privacy.userContext.enabled" = true;
        "privacy.userContext.ui.enabled" = true;
        # keep startup quiet & predictable
        "browser.aboutConfig.showWarning" = false;
        "browser.shell.checkDefaultBrowser" = false;
        "datareporting.policy.dataSubmissionEnabled" = false;
        "extensions.autoDisableScopes" = 0;
      };

      wrapped = pkgs.wrapFirefox unwrapped {
        # distinct window class per profile (handy for tiling WMs / identifying
        # which customer a window belongs to)
        wmClass = "browser-${name}";
        extraPolicies = lib.recursiveUpdate
          ({
            DisableAppUpdate = true;
            DisableTelemetry = true;
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
        extraPrefs = settingsToPrefs (basePrefs // settings) + "\n" + prefs;
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

      launcher = pkgs.writeShellApplication {
        name = "browser-${name}";
        text = ''
          ${resolveHome}
          dir="$profile_home/${profileDirName}"
          mkdir -p "$dir"
          # --no-remote + a dedicated profile lets every customer browser run
          # concurrently, fully isolated from each other and your personal one.
          exec ${lib.getExe wrapped} --no-remote --profile "$dir" "$@"
        '';
      };
    in
    {
      inherit name launcher;
      browser = wrapped;
      package = launcher;
    };
}
