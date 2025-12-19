{
  lib,
  stdenv,
  cmake,
  ninja,
  pkg-config,
  qt6,
  harfbuzz,
  freetype,
  fontconfig,
  icu,
  libjpeg,
  libpng,
  pcre2,
  libb2,
  md4c,
  double-conversion,
  zlib,
  zstd,
  libinput,
  libxkbcommon,
  xkeyboard_config,
  libdrm,
}:
qt6.overrideScope (final: prev: {
  qtbase = stdenv.mkDerivation rec {
    pname = "qtbase-minimal";
    inherit (qt6.srcs.qtbase) version src;
    inherit (qt6.qtbase) patches;

    strictDeps = true;
    enableParallelBuilding = true;

    propagatedBuildInputs = [
      #Rendering stuff
      harfbuzz
      freetype
      fontconfig
      icu
      libjpeg
      libpng
      pcre2
      libb2
      md4c
      double-conversion
      zlib
      zstd

      #QPA stuff
      (libinput.override {
        # - wacom support pulls in the entirety of Python ._.
        wacomSupport = false;
      })
      (libxkbcommon.overrideAttrs {
        # - don't depend on libx11 / libwayland
        outputs = ["out"];
        mesonFlags = [
          "-Denable-docs=false"
          "-Denable-x11=false"
          "-Denable-wayland=false"
          "-Dxkb-config-root=${xkeyboard_config}/etc/X11/xkb"
        ];
      })
      libdrm
    ];

    nativeBuildInputs = [
      cmake
      ninja
      pkg-config
    ];

    qtPluginPrefix = "lib/qt-6/plugins";
    qtQmlPrefix = "lib/qt-6/qml";

    cmakeFlags = [
      "--log-level=STATUS"
      "-DCMAKE_SYSTEM_VERSION="
      "-DINSTALL_PLUGINSDIR=${qtPluginPrefix}"
      "-DINSTALL_QMLDIR=${qtQmlPrefix}"
      "-DQT_EMBED_TOOLCHAIN_COMPILER=OFF"

      "-DINPUT_opengl=no"
      "-DFEATURE_dbus=OFF"
      "-DFEATURE_sql=OFF"
      "-DFEATURE_printsupport=OFF"
      "-DFEATURE_testlib=OFF"
      "-DFEATURE_libinput=ON"
      "-DQT_SKIP_AUTO_PLUGIN_INCLUSION=ON"
      "-DQT_QPA_PLATFORMS=linuxfb"
    ];

    env.NIX_CFLAGS_COMPILE = "-DNIXPKGS_QT_PLUGIN_PREFIX=\"${qtPluginPrefix}\"";

    inherit (qt6.qtbase) preHook setupHook fix_qt_builtin_paths fix_qt_module_paths;
    dontWrapQtApps = true;

    outputs = ["out" "dev"];
    moveToDev = false;

    postFixup = ''
      moveToOutput      "mkspecs/modules" "$dev"
      fixQtModulePaths  "$dev/mkspecs/modules"
      fixQtBuiltinPaths "$out" '*.pr?'
    '';
  };

  qttools = prev.qttools.overrideAttrs {
    # - we only need the linguist feature
    cmakeFlags =
      (map (f: "-DFEATURE_${f}=off") [
        "assistant"
        "clang"
        "qdoc"
        "designer"
        "distancefieldgenerator"
        "kmap2qmap"
        "pixeltool"
        "qev"
        "qtattributionsscanner"
        "qtdiag"
        "qtplugininfo"
        "fullqthelp"
      ])
      ++ ["-DFEATURE_linguist=on"];
  };

  qtdeclarative = prev.qtdeclarative.overrideAttrs (attrs: {
    enableParallelBuilding = true;

    # - we only need base QtQml / QtQuick
    cmakeFlags =
      attrs.cmakeFlags
      ++ (map (f: "-DFEATURE_${f}=off") [
        "qml_network"
        "qml_debug"
        "quick_designer"
        # "quick_shadereffect"
        "quickshapes_designhelpers"

        # "quickcontrols2_basic"
        # "quickcontrols2_fusion"
        "quickcontrols2_stylekit"
        "quickcontrols2_universal"
        "quickcontrols2_material"
        "quickcontrols2_imagine"
        "quickcontrols2_fluentwinui3"

        "quicktemplates2_hover"
        "quicktemplates2_multitouch"
        "quicktemplates2_calendar"
        # "quicktemplates2_container" # - can't be disabled because of a Qt bug :/
      ]);
  });

  replaceQtPkgs = pkg: recDeps: let
    recDeps' =
      if lib.isFunction recDeps
      then recDeps
      else (p: lib.any (d: d == p || (p.name or p.pname) == d) recDeps);

    replacePkgDeps = pkg:
      if lib.isDerivation pkg
      then
        pkg.overrideAttrs (old: {
          buildInputs = map replaceDep (old.buildInputs or []);
          propagatedBuildInputs = map replaceDep (old.propagatedBuildInputs or []);

          nativeBuildInputs = map replaceNativeDep (old.nativeBuildInputs or []);
          propagatedNativeBuildInputs = map replaceNativeDep (old.propagatedNativeBuildInputs or []);
        })
      else pkg;

    replaceDep = dep:
      if lib.isDerivation dep
      then
        final.${
          dep.pname or dep.name
        } or (
          if recDeps' dep
          then replacePkgDeps dep
          else dep
        )
      else dep;

    replaceNativeDep = dep:
      if lib.isDerivation dep && dep.name == "wrap-qt6-apps-hook"
      then final.wrapQtAppsHook
      else replaceDep dep;
  in
    replacePkgDeps pkg;
})
