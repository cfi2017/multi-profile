{
  description = "PRIVATE work browser profiles — pure data, no inputs, keep this repo private";

  # This flake intentionally has no inputs: it only exports profile *data*.
  # The public main flake merges `browserProfiles` and builds it with the
  # multi-profile engine, so nothing customer-specific leaks into a public repo.
  outputs = { self }: {
    browserProfiles = {

      acme = {
        browser = "zen";
        # MS Teams tenant for ACME. Each customer is a separate profile, so a
        # separate Teams/Microsoft login — no account switching.
        extensions = [ "ublock-origin" "bitwarden" "foxyproxy-standard" ];
        bookmarks = [
          { name = "Teams"; url = "https://teams.microsoft.com"; }
          { name = "Outlook"; url = "https://outlook.office.com"; }
          {
            name = "Azure";
            children = [
              { name = "Portal"; url = "https://portal.azure.com"; }
              { name = "Entra ID"; url = "https://entra.microsoft.com"; }
            ];
          }
        ];
        settings."browser.startup.homepage" = "https://teams.microsoft.com";
        # Essentials (shown across workspaces) + a pinned tab, as code.
        pins = [
          { url = "https://teams.microsoft.com"; title = "Teams"; essential = true; }
          { url = "https://outlook.office.com"; title = "Outlook"; essential = true; }
          { url = "https://portal.azure.com"; title = "Azure"; }
        ];
        pinsForce = true; # declared pins are the source of truth
        search = {
          default = "DuckDuckGo";
          add = [{
            name = "ACME Jira";
            url = "https://acme.atlassian.net/issues/?jql=text~%22{searchTerms}%22";
            alias = "@jira";
          }];
        };
        # FoxyProxy config as code (managed -> read-only in the extension).
        foxyproxy.proxies = [{
          title = "Burp (ACME)";
          type = "http";
          hostname = "127.0.0.1";
          port = 8080;
        }];
        icon = "zen-beta"; # desktop-entry icon (home-manager)
        desktopName = "ACME"; # desktop-entry app name (home-manager)
      };

      globex = {
        browser = "zen";
        bookmarks = [
          { name = "Teams"; url = "https://teams.microsoft.com"; }
          { name = "M365 Admin"; url = "https://admin.microsoft.com"; }
        ];
      };
    };

    # Optional: private routing rules, merged by the main flake's home-manager
    # config. Host globs -> profile name.
    browserRouterRules = [
      { profile = "acme"; hosts = [ "*.acme.com" "acme.atlassian.net" ]; }
      { profile = "globex"; hosts = [ "*.globex.example" ]; }
    ];
  };
}
