{
  config,
  lib,
  pkgs,
  ...
}: let
  tcfg = config.boot.initrd.luks.sddmUnlock.theme;
in {
  options.boot.initrd.luks.sddmUnlock.theme.breezeFixups = lib.mkOption {
    type = lib.types.bool;
    description = "Whether to apply theme fixups intended to get KDE Plasma's Breeze theme working.";
    default = tcfg.name == "breeze";
    defaultText = lib.literalExpression ''config.boot.initrd.luks.sddmUnlock.theme.name == "breeze"'';
  };

  config.boot.initrd.luks.sddmUnlock.theme = {
    qt5Compat = true;
    fixups = let
      toFsPath = path:
        if lib.hasInfix ":" path
        then "lib/qt-6/qml/${lib.replaceStrings ["." ":"] ["/" "/"] path}.qml"
        else "lib/qt-6/qml/${lib.replaceString "." "/" path}";

      fixup = path: cmd: {${toFsPath path} = cmd;};
      sedFixup = path: instrs: fixup path "sed -i ${lib.escapeShellArg (lib.join ";" instrs)} $target";

      stubType = module: ver: type: qml: let
        qmldirEntry = "${type} ${
          if ver != null
          then ver
          else "0.0"
        } ${pkgs.writeText "initrd-${module}-${type}-stub.qml" qml}";
      in
        fixup "${module}/qmldir" "echo ${lib.escapeShellArg qmldirEntry} >> $target";
    in
      lib.mkIf tcfg.breezeFixups (lib.mkMerge [
        #Stub out minor libkirigami features
        (stubType "org.kde.kirigami" "2.20" "MnemonicData" "")
        (stubType "org.kde.kirigami.private" "2.20" "ActionHelper" "")

        #Stub out `KAuthorized` (pulls in the config machinery & is unused)
        (stubType "org.kde.config" null "KAuthorized" "function authorize(arg) { return true; }")

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
        (fixup "org.kde.breeze.components:Battery" "truncate -s0 $target")

        #FIXME: crude patches to remove all remaining plugin uses
        (stubType "org.kde.kirigami.platform" "2.20" "Units" "import QtQml\nQtObject {}")
        (stubType "org.kde.kirigami.platform" "2.20" "Theme" "import QtQml\nQtObject {}")
        (stubType "org.kde.kirigami.platform" "2.20" "Settings" "import QtQml\nQtObject {}")
        (stubType "org.kde.kirigami.primitives" "2.20" "Icon" "import QtQml\nQtObject {}")
        (stubType "org.kde.kirigami.layouts" "2.20" "Padding" "import QtQml\nQtObject {}")

        (stubType "org.kde.ksvg" null "Svg" "import QtQml\nQtObject {}")
        (stubType "org.kde.ksvg" null "SvgItem" "import QtQml\nQtObject {}")
        (stubType "org.kde.ksvg" null "FrameSvgItem" "import QtQml\nQtObject {}")
        (stubType "org.kde.ksvg" null "ImageSet" "import QtQml\nQtObject {}")

        (stubType "org.kde.plasma.core" null "Window" "import QtQml\nQtObject {}")
        (stubType "org.kde.plasma.core" null "Theme" "import QtQml\nQtObject {}")
        (stubType "org.kde.plasma.private.keyboardindicator" null "KeyState" "import QtQml\nQtObject {}")
      ]);
  };
}
