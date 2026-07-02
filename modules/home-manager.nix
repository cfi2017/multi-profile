# Home-manager module. Wire it up from the engine flake's `homeModules.default`,
# which injects `mkLib`, `zen-browser` and `nur` from the engine's locked inputs.
{ mkLib, zen-browser, nur }:
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.multiProfile;
  system = pkgs.stdenv.hostPlatform.system;

  # rycee addon set, evaluated with allowUnfree (for wappalyzer) regardless of
  # the user's own nixpkgs config.
  addonPkgs = import pkgs.path {
    inherit system;
    config.allowUnfree = true;
    overlays = [ nur.overlays.default ];
  };
  addons = addonPkgs.nur.repos.rycee.firefox-addons;

  mkProfile = (mkLib pkgs).mkProfile {
    inherit pkgs addons;
    zen = zen-browser.packages.${system};
  };

  # Build every profile with a stable profile location (so GUI launches and the
  # URL router always hit the same per-customer profile).
  built = lib.mapAttrs
    (name: def: mkProfile name (def // { profileHome = cfg.profileHome; }))
    cfg.profiles;

  launcherExe = name:
    lib.getExe (built.${name}.launcher
      or (throw "programs.multiProfile: unknown profile '${name}'"));

  # The URL router: extract the host and dispatch to the matching profile.
  #
  # Drop empty host patterns and rules with no hosts left — an empty pattern
  # would emit an invalid `case` arm (`) exec … ;;`). Warn rather than silently
  # ignore, so a mistyped rule (e.g. `hosts = [ ]`) is visible.
  sanitizedRules =
    map (r: r // { hosts = lib.filter (h: h != "") r.hosts; }) cfg.router.rules;
  validRouterRules = lib.filter (r: r.hosts != [ ]) sanitizedRules;
  emptyRuleProfiles = map (r: r.profile) (lib.filter (r: r.hosts == [ ]) sanitizedRules);

  routerRules = lib.concatMapStringsSep "\n"
    (r: "    ${lib.concatStringsSep "|" r.hosts}) exec ${launcherExe r.profile} \"$url\" ;;")
    validRouterRules;

  router = lib.warnIf (emptyRuleProfiles != [ ])
    "programs.multiProfile.router.rules: ignoring rule(s) with no host patterns for profile(s): ${lib.concatStringsSep ", " emptyRuleProfiles}."
    (pkgs.writeShellApplication {
    name = "browser-router";
    text = ''
      url="''${1:-about:blank}"
      # strip scheme, userinfo, path and port to get the bare host
      host="''${url#*://}"
      host="''${host%%/*}"
      host="''${host##*@}"
      host="''${host%%:*}"
      shopt -s nocasematch
      case "$host" in
      ${routerRules}
        *) exec ${launcherExe cfg.defaultProfile} "$url" ;;
      esac
    '';
  });

  # one .desktop per profile, plus the router entry. `desktopName` /
  # `desktopGenericName` (per-profile keys) override the shown names.
  profileDesktopEntries = lib.mapAttrs
    (name: b: {
      name = cfg.profiles.${name}.desktopName or "Browser — ${name}";
      genericName = cfg.profiles.${name}.desktopGenericName or "Web Browser (${name})";
      exec = "${lib.getExe b.launcher} %U";
      icon = cfg.profiles.${name}.icon or "applications-internet";
      terminal = false;
      categories = [ "Network" "WebBrowser" ];
      mimeType = [ "text/html" "x-scheme-handler/http" "x-scheme-handler/https" ];
      startupNotify = true;
      settings.StartupWMClass = "browser-${name}";
    })
    built;

  routerDesktopEntry = lib.optionalAttrs cfg.router.enable {
    browser-router = {
      name = "Browser (auto-route)";
      genericName = "Web Browser";
      exec = "${lib.getExe router} %U";
      icon = "applications-internet";
      terminal = false;
      categories = [ "Network" "WebBrowser" ];
      mimeType = [ "text/html" "x-scheme-handler/http" "x-scheme-handler/https" ];
      startupNotify = true;
    };
  };

  defaultBrowserApps = lib.optionalAttrs (cfg.router.enable && cfg.router.setAsDefaultBrowser) {
    "text/html" = "browser-router.desktop";
    "x-scheme-handler/http" = "browser-router.desktop";
    "x-scheme-handler/https" = "browser-router.desktop";
    "x-scheme-handler/about" = "browser-router.desktop";
    "x-scheme-handler/unknown" = "browser-router.desktop";
  };
in
{
  options.programs.multiProfile = {
    enable = lib.mkEnableOption "declarative per-customer browser profiles";

    profiles = lib.mkOption {
      type = with lib.types; attrsOf (attrsOf anything);
      default = { };
      description = ''
        Customer profiles, keyed by name. Each value is a profile definition
        (same schema as `multi-profile.lib.mkProfile`: browser, extensions,
        bookmarks, search, foxyproxy, settings, ...). Extra desktop-entry keys:
        `icon` (name or path), `desktopName` (the shown app name, default
        "Browser — <name>") and `desktopGenericName`.
      '';
    };

    profileHome = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.dataHome}/multi-profile";
      defaultText = lib.literalExpression ''"''${config.xdg.dataHome}/multi-profile"'';
      description = "Stable directory holding the per-customer runtime profiles used by GUI launches and the router.";
    };

    defaultProfile = lib.mkOption {
      type = lib.types.str;
      description = "Profile the router falls back to when no rule matches.";
    };

    router = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Install a URL-routing 'browser' that opens links in the right customer profile.";
      };
      setAsDefaultBrowser = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Register the router as the default http(s)/html handler via xdg.mimeApps.";
      };
      rules = lib.mkOption {
        default = [ ];
        description = "Host-to-profile routing rules, evaluated in order.";
        type = lib.types.listOf (lib.types.submodule {
          options = {
            profile = lib.mkOption {
              type = lib.types.str;
              description = "Profile to open matching URLs in.";
            };
            hosts = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Shell-glob host patterns (e.g. \"*.acme.com\", \"teams.microsoft.com\").";
            };
          };
        });
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages =
      (map (b: b.launcher) (lib.attrValues built))
      ++ lib.optional cfg.router.enable router;

    xdg.desktopEntries = profileDesktopEntries // routerDesktopEntry;

    # defaultApplications only takes effect when mimeApps is enabled.
    xdg.mimeApps.enable = lib.mkIf
      (cfg.router.enable && cfg.router.setAsDefaultBrowser)
      (lib.mkDefault true);
    xdg.mimeApps.defaultApplications = lib.mkIf
      (cfg.router.enable && cfg.router.setAsDefaultBrowser)
      defaultBrowserApps;

    home.sessionVariables = lib.mkIf cfg.router.enable {
      BROWSER = lib.getExe router;
    };
  };
}
