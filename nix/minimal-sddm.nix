{
  lib,
  qt6,
  qtbase-minimal,
  kdePackages,
}: let
  qt6Min = qt6.overrideScope (final: prev: {
    qtbase = qtbase-minimal;

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
          "quick_shadereffect"
          "quickshapes_designhelpers"
          "quickcontrols2_basic"
          "quicktemplates2_hover"
          "quicktemplates2_multitouch"
          "quicktemplates2_calendar"
          # "quicktemplates2_container" # - can't be disabled because of a Qt debug :/
        ]);
    });
  });
in
  (kdePackages.sddm.unwrapped.override {
    inherit (qt6Min) qtbase qttools qtdeclarative;
  }).overrideAttrs (
    attrs: {
      pname = "sddm-minimal";
      outputs = ["out"];

      buildInputs = with qt6Min; [qtbase qtdeclarative];

      cmakeFlags =
        attrs.cmakeFlags
        ++ [
          (lib.cmakeBool "NO_SYSTEMD" true)
          (lib.cmakeBool "BUILD_MAN_PAGES" false)
        ];

      postUnpack = ''
        #Only build the greeter
        sed -i 's/Core DBus Gui Qml Quick LinguistTools Test QuickTest/Core Gui Qml Quick LinguistTools/' source/CMakeLists.txt
        sed -i '/find_package(PAM REQUIRED)/d' source/CMakeLists.txt
        sed -i '/find_package(XCB REQUIRED)/d' source/CMakeLists.txt
        sed -i '/pkg_check_modules(LIBXAU REQUIRED "xau")/d' source/CMakeLists.txt
        sed -i '/find_package(XKB REQUIRED)/d' source/CMakeLists.txt
        sed -i '/add_subdirectory(test)/d' source/CMakeLists.txt

        sed -i '/add_subdirectory(daemon)/d' source/src/CMakeLists.txt
        sed -i '/add_subdirectory(helper)/d' source/src/CMakeLists.txt

        #Remove the keyboard layout switching code
        sed -i '/include "XcbKeyboardBackend.h"/d' source/src/greeter/KeyboardModel.cpp
        sed -i '/new XcbKeyboardBackend(d)/d' source/src/greeter/KeyboardModel.cpp

        sed -i '/#nclude "waylandkeyboardbackend.h"/d' source/src/greeter/KeyboardModel.cpp
        sed -i '/new WaylandKeyboardBackend(d)/d' source/src/greeter/KeyboardModel.cpp

        sed -i '/"''${LIBXCB_INCLUDE_DIR}"/d' source/src/greeter/CMakeLists.txt
        sed -i '/XcbKeyboardBackend.cpp/d' source/src/greeter/CMakeLists.txt
        sed -i '/waylandkeyboardbackend.cpp/d' source/src/greeter/CMakeLists.txt
        sed -i '/waylandkeyboardbackend.h/d' source/src/greeter/CMakeLists.txt

        # - fix Qt6::Network dependency (previously it was a transitive dependency of Qt6::Quick, but we disable QML network support)
        sed -i '/Qt''${QT_MAJOR_VERSION}::Quick/a Qt''${QT_MAJOR_VERSION}::Network' source/src/greeter/CMakeLists.txt
      '';
    }
  )
