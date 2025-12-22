{
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
  libdrm,
  libgbm,
  libglvnd,
}:
(qt6.override {inherit stdenv;}).overrideScope (final: prev: {
  qtbase = stdenv.mkDerivation rec {
    pname = "qtbase-minimal";
    inherit (qt6.srcs.qtbase) version src;

    patches = qt6.qtbase.patches ++ [patches/qtbase-linuxfb-platform-theme.patch];

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
      libinput
      libxkbcommon
      libdrm
      libgbm
      libglvnd
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

      "-DFEATURE_dbus=OFF"
      "-DFEATURE_sql=OFF"
      "-DFEATURE_vnc=OFF"
      "-DFEATURE_printsupport=OFF"
      "-DFEATURE_testlib=OFF"
      "-DFEATURE_libinput=ON"
      "-DFEATURE_eglfs=ON"
      "-DFEATURE_eglfs_gbm=ON"
      "-DINPUT_opengl=es2"

      "-DQT_SKIP_AUTO_PLUGIN_INCLUSION=ON"
      "-DQT_QPA_PLATFORMS=linuxfb;eglfs"
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
})
