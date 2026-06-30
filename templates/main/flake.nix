{
  description = "My browser profiles (public) — composes a private work flake";

  inputs = {
    # The engine. Point this at wherever you host this repo.
    multi-profile.url = "github:YOU/multi-profile";

    # Your PRIVATE work flake. It only needs to export a `browserProfiles`
    # attrset (pure data) — see examples/work in the engine repo.
    work.url = "git+ssh://git@your.git.host/you/work-browser-profiles.git";
  };

  outputs = { self, multi-profile, work, ... }:
    multi-profile.lib.mkFlake {
      # Both flakes "add profiles" by contributing to this merged attrset.
      # Work (private) profiles + your own public ones:
      profiles = work.browserProfiles // {

        # A public profile defined right here.
        personal = {
          browser = "zen"; # "zen", "zen-twilight", or "firefox"
          # extensions default to: ublock-origin, bitwarden, foxyproxy-standard,
          # wappalyzer, dearrow, sponsorblock. Override per profile:
          # extensions = [ "ublock-origin" "bitwarden" ];
          bookmarks = [
            { name = "Nixpkgs"; url = "https://github.com/NixOS/nixpkgs"; }
            {
              name = "Reading";
              children = [
                { name = "HN"; url = "https://news.ycombinator.com"; }
              ];
            }
          ];
        };
      };
    };
}
