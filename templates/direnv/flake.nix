{
  description = "This project's browser profile — composes the multi-profile engine";

  inputs = {
    # The engine. Point this at wherever you host the multi-profile repo.
    # This is the ONLY place the engine is referenced — your .envrc just does
    # `use flake`, so the direnv never mentions multi-profile directly.
    multi-profile.url = "github:YOU/multi-profile";
  };

  outputs = { self, multi-profile, ... }:
    multi-profile.lib.mkFlake {
      # Exactly one profile for THIS direnv. Because it's the only profile,
      # `use flake` (see .envrc) exposes the short `web` command directly —
      # no `.#name` needed. Rename `this` to whatever suits the project; it
      # becomes the launcher name (`browser-this`) and the window class.
      profiles.this = {
        browser = "zen"; # "zen", "zen-twilight", or "firefox"

        # Defaults: ublock-origin, bitwarden, foxyproxy-standard, wappalyzer,
        # dearrow, sponsorblock. Override per profile:
        # extensions = [ "ublock-origin" "bitwarden" ];

        bookmarks = [
          { name = "Nixpkgs"; url = "https://github.com/NixOS/nixpkgs"; }
        ];

        # Zen essentials (essential = true) + pinned tabs, as code. Applied to
        # the profile from the second launch on; edit later without a rebuild.
        pins = [
          { url = "https://github.com/NixOS/nixpkgs"; title = "Nixpkgs"; essential = true; }
          { url = "https://search.nixos.org"; title = "Search"; }
        ];
        # pinsForce = true;   # make the list above the source of truth

        # settings."browser.startup.homepage" = "https://example.com";
        # search.default = "DuckDuckGo";
        # foxyproxy.proxies = [
        #   { title = "Burp"; type = "http"; hostname = "127.0.0.1"; port = 8080; }
        # ];
      };
    };
}
