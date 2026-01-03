## boot\.initrd\.luks\.sddmUnlock\.enable



Whether to enable LUKS unlock using SDDM in initrd\.



*Type:*
boolean



*Default:*
` false `



*Example:*
` true `

*Declared by:*
 - [nix/nixos/module\.nix](nix/nixos/module.nix)



## boot\.initrd\.luks\.sddmUnlock\.packages



The luks-stage1-sddm package scope to use



*Type:*
attribute set



*Default:*
` pkgs.luks-stage1-sddm `

*Declared by:*
 - [nix/nixos/module\.nix](nix/nixos/module.nix)



## boot\.initrd\.luks\.sddmUnlock\.availableKmsModules

Kernel modules to make available for enabling KMS support\. These kernel modules will be stored in the squashed closure\.



*Type:*
list of string



*Default:*
` [ ] `



*Example:*

```
[
  "amdgpu"
]
```

*Declared by:*
 - [nix/nixos/module\.nix](nix/nixos/module.nix)



## boot\.initrd\.luks\.sddmUnlock\.displayDpi



The DPI of the output display\. Note that DPI may not be specified per-screen, and must be identical when multiple monitors are in-use\.



*Type:*
positive integer, meaning >0



*Default:*
` 96 `

*Declared by:*
 - [nix/nixos/module\.nix](nix/nixos/module.nix)



## boot\.initrd\.luks\.sddmUnlock\.displayOutputs



Configuration of output display to use with SDDM\. Screens are arranged in a virtual desktop-like layout\.



*Type:*
attribute set of (submodule)



*Default:*
` { } `

*Declared by:*
 - [nix/nixos/module\.nix](nix/nixos/module.nix)



## boot\.initrd\.luks\.sddmUnlock\.displayOutputs\.\<name>\.mode



The output mode to set the screen to\.



*Type:*
null or string



*Default:*
` null `



*Example:*
` "1920x1080" # or: "off", "current", "preferred", "skip", "1920x1080@60", ... `

*Declared by:*
 - [nix/nixos/module\.nix](nix/nixos/module.nix)



## boot\.initrd\.luks\.sddmUnlock\.displayOutputs\.\<name>\.virtualIndex



The index of the screen in the virtual desktop\. Screens are arranged from left-to-right in order of ascending virtual indices\.



*Type:*
null or (unsigned integer, meaning >=0)



*Default:*
` null `

*Declared by:*
 - [nix/nixos/module\.nix](nix/nixos/module.nix)



## boot\.initrd\.luks\.sddmUnlock\.displayOutputs\.\<name>\.virtualPos



The position of the screen on the virtual desktop\. This can be used to override the default positioning logic based on ` virtualIndex `\.



*Type:*
null or (submodule)



*Default:*
` null `

*Declared by:*
 - [nix/nixos/module\.nix](nix/nixos/module.nix)



## boot\.initrd\.luks\.sddmUnlock\.driDevice



The DRI device to use\. If not specified, a DRI device is picked automatically\.



*Type:*
null or string



*Default:*
` null `



*Example:*
` "/dev/dri/card2" `

*Declared by:*
 - [nix/nixos/module\.nix](nix/nixos/module.nix)



## boot\.initrd\.luks\.sddmUnlock\.extraClosureRules



Extra exclusion rules to apply when building the SDDM initrd closure\.



*Type:*
list of string



*Default:*
` [ ] `



*Example:*

```
[
  "${somePkg}/excludeFile"
  "!${somePkg}/includeFile"

  "${somePkg}/excludeFolder/"
  "!${somePkg}/includeFolder/"
]
```

*Declared by:*
 - [nix/nixos/squashed-closure\.nix](nix/nixos/squashed-closure.nix)



## boot\.initrd\.luks\.sddmUnlock\.kmsModules



Kernel modules to explicitly load for enabling KMS support\. These kernel modules will be stored in the squashed closure\.



*Type:*
list of string



*Default:*
` [ ] `



*Example:*

```
[
  "nvidia"
]
```

*Declared by:*
 - [nix/nixos/module\.nix](nix/nixos/module.nix)



## boot\.initrd\.luks\.sddmUnlock\.locale



The locale used by the SDDM greeter\.



*Type:*
string



*Default:*
` config.i18n.defaultLocale `

*Declared by:*
 - [nix/nixos/module\.nix](nix/nixos/module.nix)



## boot\.initrd\.luks\.sddmUnlock\.luksDevices



The name of LUKS devices that will be unlocked using SDDM\.
There must be a corresponding entry in ` boot.initrd.luks.devices ` for each listed device\.



*Type:*
list of string

*Declared by:*
 - [nix/nixos/module\.nix](nix/nixos/module.nix)



## boot\.initrd\.luks\.sddmUnlock\.pinPkgs



Pin the SDDM initrd packages to the specific nixpkgs instance\.
Can be used to prevent excessive rebuilds of the squashed SDDM closure\.
When using the flake entrypoint, this will default to the locked nixpkgs input\.



*Type:*
null or (function that evaluates to a(n) (attribute set))



*Default:*
` null `

*Declared by:*
 - [nix/nixos/squashed-closure\.nix](nix/nixos/squashed-closure.nix)



## boot\.initrd\.luks\.sddmUnlock\.rootBuildDeps



Keep the build dependencies of the SDDM initrd closure alive\.



*Type:*
boolean



*Default:*
` true `

*Declared by:*
 - [nix/nixos/squashed-closure\.nix](nix/nixos/squashed-closure.nix)



## boot\.initrd\.luks\.sddmUnlock\.settings



Extra settings merged in and overwriting defaults in sddm\.conf\.



*Type:*
attribute set of section of an INI file (attrs of INI atom (null, bool, int, float or string) or a list of them for duplicate keys)



*Default:*
` { } `

*Declared by:*
 - [nix/nixos/module\.nix](nix/nixos/module.nix)



## boot\.initrd\.luks\.sddmUnlock\.sideloadClosure



Don’t store the squashed SDDM closure in the initrd itself, and instead store it directly on the EFI partition\.
This can be used to reduce the size of the generated initrd\.



*Type:*
boolean



*Default:*
` config.boot.loader.systemd-boot.enable || (config.boot.loader.grub.enable && config.boot.loader.grub.efiSupport) `

*Declared by:*
 - [nix/nixos/squashed-closure\.nix](nix/nixos/squashed-closure.nix)



## boot\.initrd\.luks\.sddmUnlock\.syncPasswordChanges



Change the LUKS password when the password of an early-logon user gets changed\.



*Type:*
boolean



*Default:*
` true `

*Declared by:*
 - [nix/nixos/module\.nix](nix/nixos/module.nix)



## boot\.initrd\.luks\.sddmUnlock\.theme\.packages



Extra SDDM themes / Qt plugins / QML libraries to add to the initrd environment\.



*Type:*
list of package



*Default:*
` [ ] `

*Declared by:*
 - [nix/nixos/theming\.nix](nix/nixos/theming.nix)



## boot\.initrd\.luks\.sddmUnlock\.theme\.breezeFixups



Whether to apply theme fixups intended to get KDE Plasma’s Breeze theme working\.



*Type:*
boolean



*Default:*
` config.boot.initrd.luks.sddmUnlock.theme.name == "breeze" `

*Declared by:*
 - [nix/nixos/breeze-fixups\.nix](nix/nixos/breeze-fixups.nix)



## boot\.initrd\.luks\.sddmUnlock\.theme\.cursorHwAcceleration



Whether or not to use hardware-accelerated for drawing the greeter cursor\.



*Type:*
boolean



*Default:*
` true `

*Declared by:*
 - [nix/nixos/theming\.nix](nix/nixos/theming.nix)



## boot\.initrd\.luks\.sddmUnlock\.theme\.cursorIcons



The icon set to use for the mouse cursor, or ` null ` for the default Qt cursors\.



*Type:*
null or string



*Default:*
` null `

*Declared by:*
 - [nix/nixos/theming\.nix](nix/nixos/theming.nix)



## boot\.initrd\.luks\.sddmUnlock\.theme\.cursorSize



The size of cursor to use in pixels\.



*Type:*
signed integer



*Default:*
` 32 `

*Declared by:*
 - [nix/nixos/theming\.nix](nix/nixos/theming.nix)



## boot\.initrd\.luks\.sddmUnlock\.theme\.defaultFonts



Set the default font families to use for various font types\.



*Type:*
attribute set of list of string



*Default:*
` { } `



*Example:*

```
{
  emoji = [
    "Noto Color Emoji"
  ];
  monospace = [
    "Hack"
  ];
  sans-serif = [
    "Noto Sans"
  ];
  serif = [
    "Noto Serif"
  ];
}
```

*Declared by:*
 - [nix/nixos/theming\.nix](nix/nixos/theming.nix)



## boot\.initrd\.luks\.sddmUnlock\.theme\.envVars



Environment variables to set for the SDDM greeter process\.



*Type:*
attribute set of string



*Default:*
` { } `



*Example:*

```
{
  QT_QPA_SYSTEM_ICON_THEME = "breeze";
}
```

*Declared by:*
 - [nix/nixos/theming\.nix](nix/nixos/theming.nix)



## boot\.initrd\.luks\.sddmUnlock\.theme\.extraPaths



Extra paths to include in the SDDM theme environment\.



*Type:*
list of string



*Default:*
` [ ] `



*Example:*

```
[
  "/share/plasma/desktoptheme/default"
  "/share/icons/breeze"
]
```

*Declared by:*
 - [nix/nixos/theming\.nix](nix/nixos/theming.nix)



## boot\.initrd\.luks\.sddmUnlock\.theme\.fixups



A set of commands which are used to fix up files in the SDDM theme environment\.



*Type:*
attribute set of strings concatenated with “\\n”



*Default:*
` { } `



*Example:*

```
{
  "some/directory/" = "echo 'hi' >> $target";
  "some/file" = "rm $target";
}
```

*Declared by:*
 - [nix/nixos/theming\.nix](nix/nixos/theming.nix)



## boot\.initrd\.luks\.sddmUnlock\.theme\.fontPackages



Font packages to make available in the initrd environment\.



*Type:*
list of package



*Default:*
` [ ] `

*Declared by:*
 - [nix/nixos/theming\.nix](nix/nixos/theming.nix)



## boot\.initrd\.luks\.sddmUnlock\.theme\.name



Greeter theme to use\.



*Type:*
string



*Default:*
` config.services.displayManager.sddm.theme `

*Declared by:*
 - [nix/nixos/theming\.nix](nix/nixos/theming.nix)



## boot\.initrd\.luks\.sddmUnlock\.theme\.qmlModules



A set of initrd-suitable QML modules which are used to replace existing ones in the SDDM theme environment\.



*Type:*
attribute set of package



*Default:*
` { } `



*Example:*

```
{
  "org.kde.ksvg" = pkgs.luks-stag1-sddm.kde-minimal.ksvg;
}
```

*Declared by:*
 - [nix/nixos/theming\.nix](nix/nixos/theming.nix)



## boot\.initrd\.luks\.sddmUnlock\.theme\.qt5Compat



Whether to enable support for the ` Qt5Compat ` QML modules within the SDDM theme environment\.



*Type:*
boolean



*Default:*
` false `

*Declared by:*
 - [nix/nixos/theming\.nix](nix/nixos/theming.nix)



## boot\.initrd\.luks\.sddmUnlock\.theme\.qtSwRendering



Use Qt Quick’s software rendering backend instead of a OpenGL ES / Mesa3D llvmpipe-backed renderer\.
Can reduce the SDDM closure size, but may result in reduced graphical fidelity\.
Does not support multiple monitors, and will always render to a single output (which may be selected using ` QT_QPA_EGLFS_KMS_CONNECTOR_INDEX `)\.



*Type:*
boolean



*Default:*
` false `

*Declared by:*
 - [nix/nixos/theming\.nix](nix/nixos/theming.nix)



## boot\.initrd\.luks\.sddmUnlock\.theme\.syncUserAvatars



Whether to copy user avatars into the initrd using the initrd secrets mechanism to be shown by the stage 1 SDDM greeter\.



*Type:*
boolean



*Default:*
` true `

*Declared by:*
 - [nix/nixos/theming\.nix](nix/nixos/theming.nix)



## boot\.initrd\.luks\.sddmUnlock\.users



Users which should be available to log in as\.



*Type:*
list of string

*Declared by:*
 - [nix/nixos/module\.nix](nix/nixos/module.nix)


