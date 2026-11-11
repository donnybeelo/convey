{
  description = "Dev shell for Convey";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          shellHook = ''
            # TLS/proxy backends for GIO (libsoup, WebKit, GOA IMAP/SMTP)
            export GIO_EXTRA_MODULES="${pkgs.glib-networking}/lib/gio/modules''${GIO_EXTRA_MODULES:+:$GIO_EXTRA_MODULES}"

            # GSettings schemas for gsettings-desktop-schemas and GTK
            export XDG_DATA_DIRS="${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk4}/share/gsettings-schemas/${pkgs.gtk4.name}''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"

            # Media playback plugins for gstreamer
            export GST_PLUGIN_SYSTEM_PATH_1_0="${
              pkgs.lib.makeSearchPath "lib/gstreamer-1.0" (
                with pkgs.gst_all_1;
                [
                  gstreamer
                  gst-plugins-base
                  gst-plugins-bad
                  gst-libav
                ]
              )
            }"
          '';

          nativeBuildInputs = with pkgs; [
            meson
            ninja
            cmake
            gnumake
            pkg-config
            vala
            gobject-introspection
            gettext
            itstool
            desktop-file-utils
            appstream
            wrapGAppsHook4
            git
            python3
            graphviz
            gdb
            vala-language-server
          ];

          buildInputs =
            (with pkgs; [
              glib
              glib-networking
              gsettings-desktop-schemas
              gtk4
              libadwaita
              webkitgtk_6_0
              gmime3
              sqlite
              cairo
              enchant_2
              folks
              gcr_4
              libgee
              gnome-online-accounts
              icu
              isocodes
              json-glib
              libpeas2
              libsecret
              libsoup_3
              libstemmer
              libunwind
              libxml2
              libytnef
            ])
            ++ (with pkgs.gst_all_1; [
              gstreamer
              gst-plugins-base
              gst-plugins-bad
              gst-libav
            ]);
        };
      });
    };
}
