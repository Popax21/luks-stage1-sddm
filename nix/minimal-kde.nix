{
  lib,
  cmake,
  ninja,
  kdePackages,
  qt6-minimal,
  ...
}: let
  kdePackages' = kdePackages.overrideScope (final: prev: {kirigami = prev.kirigami.unwrapped;});
  kdePackages'' = kdePackages'.overrideScope (_: lib.mapAttrs (_: qt6-minimal.replaceQtPkgs));
in
  kdePackages''.overrideScope (final: prev: {
    kconfig = prev.kconfig.overrideAttrs (old: {
      cmakeFlags = (old.cmakeFlags or []) ++ ["-DUSE_DBUS=OFF"];
    });
    karchive = prev.karchive.overrideAttrs (old: {
      cmakeFlags = (old.cmakeFlags or []) ++ ["-DWITH_BZIP2=OFF" "-DWITH_LIBLZMA=OFF" "-DWITH_OPENSSL=OFF" "-DWITH_LIBZSTD=OFF"];
    });
    kcoreaddons = prev.kcoreaddons.overrideAttrs (old: {
      cmakeFlags = (old.cmakeFlags or []) ++ ["-DUSE_DBUS=OFF"];
    });
    kguiaddons = prev.kguiaddons.overrideAttrs (old: {
      cmakeFlags = (old.cmakeFlags or []) ++ ["-DUSE_DBUS=OFF" "-DWITH_X11=OFF" "-DWITH_WAYLAND=OFF" "-DBUILD_PYTHON_BINDINGS=OFF"];
    });
    kirigami = prev.kirigami.overrideAttrs (old: {
      patches = (old.patches or []) ++ [patches/kirigami-no-http-icons.patch];
      cmakeFlags = (old.cmakeFlags or []) ++ ["-DUSE_DBUS=OFF"];
    });

    kiconthemes = prev.kiconthemes.overrideAttrs (old: {
      patches = (old.patches or []) ++ [patches/kiconthemes-minimal.patch];
      cmakeFlags = (old.cmakeFlags or []) ++ ["-DUSE_DBUS=OFF" "-DKICONTHEMES_USE_QTQUICK=OFF"];

      buildInputs = with final; [qt6-minimal.qtsvg karchive ksvg kcolorscheme breeze-icons];
      nativeBuildInputs = [cmake ninja final.extra-cmake-modules];
      propagatedBuildInputs = [];

      outputs = ["out"];
      dontWrapQtApps = true;
    });
    breeze-icons = prev.breeze-icons.overrideAttrs (old: {
      cmakeFlags = (old.cmakeFlags or []) ++ ["-DSKIP_INSTALL_ICONS=ON"];
    });

    libplasma = prev.libplasma.overrideAttrs (old: {
      patches = (old.patches or []) ++ [patches/libplasma-minimal.patch];
      cmakeFlags = (old.cmakeFlags or []) ++ ["-DUSE_DBUS=OFF"];

      buildInputs = with final; [qt6-minimal.qtdeclarative kconfig kcoreaddons kguiaddons ki18n kiconthemes kirigami ksvg kcolorscheme];
      nativeBuildInputs = [cmake ninja final.extra-cmake-modules];
      propagatedBuildInputs = [];

      outputs = ["out"];
      dontWrapQtApps = true;
    });

    plasma-workspace = prev.plasma-workspace.overrideAttrs {
      postPatch = "ln -sf ${patches/plasma-workspace-CMakeLists.txt} CMakeLists.txt";
      postInstall = "";
      postFixup = "";

      buildInputs = [qt6-minimal.qtdeclarative final.kguiaddons];
      nativeBuildInputs = [cmake ninja final.extra-cmake-modules];
      propagatedBuildInputs = [];

      outputs = ["out"];
      dontWrapQtApps = true;
    };
  })
