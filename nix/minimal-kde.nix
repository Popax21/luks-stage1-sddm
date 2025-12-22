{
  stdenv,
  cmake,
  ninja,
  kdePackages,
  qt6-minimal,
  qt6Packages,
  ...
}: let
  qt6Packages' = qt6Packages.overrideScope (_: _: qt6-minimal);
in
  (kdePackages.override {qt6Packages = qt6Packages';}).overrideScope (final: prev: {
    inherit stdenv;
    qt6 = qt6-minimal;

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
    kirigami = prev.kirigami.unwrapped.overrideAttrs (old: {
      patches = (old.patches or []) ++ [patches/kirigami-no-http-icons.patch];
      cmakeFlags = (old.cmakeFlags or []) ++ ["-DUSE_DBUS=OFF"];
      passthru.unwrapped = final.kirigami;
    });

    kiconthemes = prev.kiconthemes.overrideAttrs (old: {
      patches = (old.patches or []) ++ [patches/kiconthemes-minimal.patch];
      cmakeFlags = (old.cmakeFlags or []) ++ ["-DUSE_DBUS=OFF" "-DKICONTHEMES_USE_QTQUICK=OFF"];

      buildInputs = with final; [extra-cmake-modules qtsvg karchive ksvg kcolorscheme breeze-icons];
      nativeBuildInputs = [cmake ninja];
      propagatedBuildInputs = [];

      outputs = ["out"];
      dontWrapQtApps = true;
    });
    breeze-icons = prev.breeze-icons.overrideAttrs (old: {
      cmakeFlags = (old.cmakeFlags or []) ++ ["-DSKIP_INSTALL_ICONS=ON"];
    });
    breeze-cursors = final.breeze.overrideAttrs (old: {
      cmakeFlags = (old.cmakeFlags or []) ++ ["-DBUILD_QT5=OFF" "-DBUILD_QT6=OFF" "-DBUILD_TESTING=OFF"];
      postInstall = "";

      buildInputs = with final; [extra-cmake-modules qtbase];
      nativeBuildInputs = [cmake ninja];
      propagatedBuildInputs = [];

      outputs = ["out"];
      dontWrapQtApps = true;
    });

    libplasma = prev.libplasma.overrideAttrs (old: {
      patches = (old.patches or []) ++ [patches/libplasma-minimal.patch];
      cmakeFlags = (old.cmakeFlags or []) ++ ["-DUSE_DBUS=OFF"];

      buildInputs = with final; [extra-cmake-modules qtdeclarative kconfig kcoreaddons kguiaddons ki18n kiconthemes kirigami ksvg kcolorscheme];
      nativeBuildInputs = [cmake ninja];
      propagatedBuildInputs = [];

      outputs = ["out"];
      dontWrapQtApps = true;
    });

    plasma-workspace = prev.plasma-workspace.overrideAttrs {
      postPatch = "ln -sf ${patches/plasma-workspace-CMakeLists.txt} CMakeLists.txt";
      postInstall = "";
      postFixup = "";

      buildInputs = with final; [extra-cmake-modules qtdeclarative kguiaddons];
      nativeBuildInputs = [cmake ninja];
      propagatedBuildInputs = [];

      outputs = ["out"];
      dontWrapQtApps = true;
    };
  })
