{
  lib,
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
      patches = (old.patches or []) ++ [./kirigami-no-http-icons.patch];
    });
  })
