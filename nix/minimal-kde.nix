{
  lib,
  stdenv,
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
      cmakeFlags = (old.cmakeFlags or []) ++ ["-DUSE_DBUS=OFF"];
      patches = (old.patches or []) ++ [patches/kirigami-no-http-icons.patch];
    });

    # - we don't want anything of libplasma except for a HEAVILY stripped down corebindingsplugin to initialize KI18n
    libplasma = stdenv.mkDerivation {
      pname = "libplasma-stub";
      inherit (prev.libplasma) version;

      src = patches/libplasma-stub;

      buildInputs = [qt6-minimal.qtdeclarative final.ki18n final.extra-cmake-modules];
      nativeBuildInputs = [cmake ninja];

      cmakeFlags = ["-DQT_MAJOR_VERSION=6"];
      dontWrapQtApps = true;
    };

    plasma-workspace = prev.plasma-workspace.overrideAttrs {
      postPatch = "ln -sf ${patches/plasma-workspace-CMakeLists.txt} CMakeLists.txt";
      postInstall = "";
      postFixup = "";

      buildInputs = [qt6-minimal.qtdeclarative final.extra-cmake-modules final.kguiaddons];
      nativeBuildInputs = [cmake ninja];
      propagatedBuildInputs = [];

      outputs = ["out"];
      dontWrapQtApps = true;
    };
  })
