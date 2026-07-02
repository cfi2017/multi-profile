{
  description = "Isolated, declarative Zen/Firefox profiles (extensions + bookmarks as code) for use in direnvs or your system";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Zen browser (community flake; provides *-unwrapped we can wrapFirefox).
    zen-browser.url = "github:0xc000022070/zen-browser-flake";
    zen-browser.inputs.nixpkgs.follows = "nixpkgs";

    # Packaged, signed Firefox extensions (nur.repos.rycee.firefox-addons).
    nur.url = "github:nix-community/nur";
  };

  outputs =
    { self
    , nixpkgs
    , flake-utils
    , zen-browser
    , nur
    ,
    }:
    let
      mkLib = pkgs: import ./lib { inherit (pkgs) lib; };

      defaultSystems = [ "x86_64-linux" "aarch64-linux" ];
    in
    {
      # ---- system-independent library (the public API) --------------------
      lib = {
        inherit mkLib;
        defaultExtensions = (import ./lib { lib = nixpkgs.lib; }).defaultExtensions;

        # The main entrypoint for downstream flakes.
        #
        #   multiProfile.lib.mkFlake {
        #     profiles = work.browserProfiles // { personal = { ... }; };
        #   }
        #
        # Returns { packages, apps, devShells } across `systems`. Downstream
        # flakes need NO inputs other than this one (zen + addons are bundled).
        mkFlake =
          { profiles
          , systems ? defaultSystems
          , overlays ? [ ]
          , # wappalyzer (a default extension) is unfree, so allow it by default.
            config ? { allowUnfree = true; }
          , # short, profile-agnostic command exposed inside each per-profile
            # devShell (i.e. in a direnv). Same name everywhere -> muscle memory.
            command ? "web"
          , nixpkgs ? self.inputs.nixpkgs
          ,
          }:
          flake-utils.lib.eachSystem systems (system:
          let
            pkgs = import nixpkgs {
              inherit system config;
              overlays = overlays ++ [ nur.overlays.default ];
            };
            mp = mkLib pkgs;
            # rycee addon set, evaluated against *our* pkgs so its config
            # (allowUnfree, for wappalyzer) applies.
            addons = pkgs.nur.repos.rycee.firefox-addons;
            zen = zen-browser.packages.${system};
            build = mp.mkProfile { inherit pkgs zen addons; };
            built = pkgs.lib.mapAttrs build profiles;

            # short alias -> this profile's launcher
            webBin = b:
              pkgs.writeShellScriptBin command ''
                exec ${pkgs.lib.getExe b.launcher} "$@"
              '';
          in
          {
            # `nix run .#<customer>` and a launcher per profile.
            packages = pkgs.lib.mapAttrs (_: b: b.launcher) built;

            apps =
              pkgs.lib.mapAttrs
                (_: b: {
                  type = "app";
                  program = pkgs.lib.getExe b.launcher;
                })
                built;

            # `use flake .#<customer>` in a direnv exposes BOTH the short
            # `${command}` command and the explicit `browser-<customer>` one.
            # The default shell has every `browser-*` launcher.
            devShells =
              pkgs.lib.mapAttrs
                (_: b: pkgs.mkShell { packages = [ b.launcher (webBin b) ]; })
                built
              // {
                # The default shell carries every `browser-*` launcher. When a
                # flake defines exactly ONE profile (the per-direnv variant:
                # your project's own flake composes this engine), the short
                # `${command}` alias is unambiguous, so add it too — that lets
                # a project `.envrc` use a bare `use flake` and get `${command}`.
                default = pkgs.mkShell {
                  packages =
                    map (b: b.launcher) (pkgs.lib.attrValues built)
                    ++ pkgs.lib.optional
                      (pkgs.lib.length (pkgs.lib.attrValues built) == 1)
                      (webBin (pkgs.lib.head (pkgs.lib.attrValues built)));
                };
              };
          });
      };

      # Home-manager module: installs launchers + desktop entries and a
      # URL-routing default browser. Captures the engine's locked inputs.
      homeModules.default = import ./modules/home-manager.nix {
        inherit mkLib zen-browser nur;
      };
      homeModules.multiProfile = self.homeModules.default;

      templates.default = {
        path = ./templates/main;
        description = "Public main flake composing a private work flake into per-customer browser profiles";
      };
      templates.main = self.templates.default;

      templates.direnv = {
        path = ./templates/direnv;
        description = "Per-project flake: composes this engine into a single per-direnv browser (bare `use flake`)";
      };
    }
    # ---- a runnable demo so this repo works standalone ---------------------
    // flake-utils.lib.eachSystem defaultSystems (system:
    let
      demo = self.lib.mkFlake {
        systems = [ system ];
        # a Zen demo showing essentials + pinned tabs as code
        profiles.zen-demo = {
          browser = "zen";
          pins = [
            { url = "https://teams.microsoft.com"; title = "Teams"; essential = true; }
            { url = "https://outlook.office.com"; title = "Outlook"; essential = true; }
            { url = "https://github.com"; title = "GitHub"; }
          ];
          pinsForce = true; # declared pins are the source of truth
        };
        profiles.demo = {
          browser = "firefox"; # firefox-unwrapped is cached; fast to build
          bookmarks = [
            {
              name = "Teams";
              url = "https://teams.microsoft.com";
            }
            {
              name = "Azure";
              children = [
                {
                  name = "Portal";
                  url = "https://portal.azure.com";
                }
                {
                  name = "Entra";
                  url = "https://entra.microsoft.com";
                }
              ];
            }
          ];
          settings."browser.startup.homepage" = "https://teams.microsoft.com";
          search = {
            default = "DuckDuckGo";
            add = [
              {
                name = "Nix Packages";
                url = "https://search.nixos.org/packages?query={searchTerms}";
                alias = "@np";
              }
            ];
          };
          foxyproxy.proxies = [
            {
              title = "Burp";
              type = "http";
              hostname = "127.0.0.1";
              port = 8080;
            }
          ];
        };
      };
    in
    {
      packages =
        demo.packages.${system}
        // {
          default = demo.packages.${system}.demo;
        };
      apps = demo.apps.${system};
      devShells = demo.devShells.${system};
      checks.demo-browser =
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
            overlays = [ nur.overlays.default ];
          };
          mp = self.lib.mkLib pkgs;
          built =
            mp.mkProfile
              {
                inherit pkgs;
                zen = zen-browser.packages.${system};
                addons = pkgs.nur.repos.rycee.firefox-addons;
              }
              "check"
              { browser = "firefox"; };
        in
        built.browser;
    });
}
