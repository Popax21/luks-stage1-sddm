{
  config,
  lib,
  ...
}: let
  cfg = config.boot.initrd.luks.sddmUnlock;
in {
  options.boot.initrd.luks.sddmUnlock.theme.breezeFixups = lib.mkOption {
    type = lib.types.bool;
    description = "Whether to apply theme fixups intended to get KDE Plasma's Breeze theme working.";
    default = cfg.theme.name == "breeze";
    defaultText = lib.literalExpression ''config.boot.initrd.luks.sddmUnlock.theme.name == "breeze"'';
  };

  config.boot.initrd.luks.sddmUnlock.theme = lib.mkIf cfg.theme.breezeFixups {
    qt5Compat = true;

    qmlModules = with cfg.packages.kde-minimal; {
      "org.kde.config" = kconfig;
      "org.kde.ksvg" = ksvg;
      "org.kde.kirigami" = kirigami;
      "org.kde.plasma.core" = libplasma;
      "org.kde.breeze.components" = plasma-workspace;
      "org.kde.plasma.private.keyboardindicator" = plasma-workspace;
    };

    fixups = let
      toFsPath = path:
        if lib.hasInfix ":" path
        then "lib/qt-6/qml/${lib.replaceStrings ["." ":"] ["/" "/"] path}.qml"
        else "lib/qt-6/qml/${lib.replaceString "." "/" path}";

      fixup = path: cmd: {${toFsPath path} = cmd;};
      sedFixup = path: instrs: fixup path "sed -i ${lib.escapeShellArg (lib.join ";" instrs)} $target";
    in
      lib.mkMerge [
        #The `WallpaperFader` type has an unused import
        (sedFixup "org.kde.breeze.components:WallpaperFader" ["/import org.kde.plasma.private.sessions/d"])

        #The `Clock` type pulls in the plasma5 support layer... to fetch the current time ._.
        (sedFixup "org.kde.breeze.components:Clock" [
          # - switch out the time source
          ''s/timeSource\.data\["Local"\]\["DateTime"\]/new Date()/''
          # - get rid of the old one
          "/plasma5support/d"
          "/P5Support.DataSource {/,/}/d"
        ])

        #Don't use the Wayland virtual keyboard impl
        (sedFixup "org.kde.breeze.components:VirtualKeyboardLoader" ["s/VirtualKeyboard_wayland.qml/VirtualKeyboard.qml/"])

        #The battery indicator doesn't work (depends on org.kde.Solid) and pulls in the entirety of plasma-workspace
        (fixup "org.kde.breeze.components:Battery" "echo -ne 'import QtQuick\\nItem {}' > $target")
      ];

    cursorIcons = "breeze_cursors";
    packages = [cfg.packages.kde-minimal.breeze-cursors];

    envVars.QT_QPA_SYSTEM_ICON_THEME = "breeze";

    extraPaths = ["/share/plasma/desktoptheme/default"];
  };
}
