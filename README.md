# Stage 1 SDDM LUKS unlock

This repository contains a NixOS module which allows users to run SDDM within the NixOS stage 1 / initrd environment as a graphical interface for entering their LUKS password.
The entered password is also used to seamlessly log in as the selected user once the disk has been unlocked, also unlocking e.g. the KDE wallet in the process.

To get started, import the NixOS module (either from the `nixosModules.default` flake output, or by directly importing `${repo}/nix/nixos`), then enable the module using
```nix
boot.initrd.luks.sddmUnlock = {
    enable = true;
    users = ["yourUser"];
    luksDevices = ["yourDriveLabel"];
    kmsModules = ["amdgpu"]; # - or ["nvidia_drm"]
};
```

This will require aprox. 60-100MB of disk space to store SDDM and its (transitive) dependencies, depending on your SDDM theme.
When using a compatible EFI bootloader, this disk space is only utilized once for all your NixOS generations by storing all SDDM data in a single side-loaded integrity-checked file next to your initrd.
If not, this file is instead added to each NixOS generation's initrd individually, inflating its size accordingly.

In case the SDDM data was corrupted / tampered with, or any other error occurs, the system will fall back to the regular console TTY password prompt.
You may also exit the initrd SDDM at any time by pressing Ctrl+Esc / Shift+Esc, or by holding Esc while the system boots.
As such there should be no circumstances where usage of this module results in your system becoming unusable, however no warranties are given regardless - use at your own risk!

## How does it work?
 - a version of the SDDM greeter binary is built against a minimal Qt6 package set configured to directly render to the screen using Linux's DRI / DRM subsystem
   - this is combined with a LLVMpipe-only Mesa3D build to support more advanced graphical effects (if enabled)
 - a custom SDDM daemon is used to hook this SDDM greeter up to the systemd password agent system, which forwards any password inputs to the cryptsetup LUKS unlocking process
 - if the LUKS unlock succeeds, then the SDDM daemon hands off the login request to the regular system's PAM stack once booted
   - this is accomplished by configuring the stage 2 SDDM to perform an automatic login, while handing off the password to use for the login to a custom PAM module using the kernel keyring
 - all new binaries / files needed in the initrd are bundled into a highly compressed squashfs image which is either copied into the initrd, or stored alongside it (with the initrd validating the hash of the file)
 - if the user choses to change their password, the custom PAM module additionally takes care of automatically changing the LUKS password as well (if enabled)

## Configuration options

See [here](MODULE_OPTIONS.md).


## TODO

 - as of right now, multi-monitor support is very screwy at best
   - support for Qt6 eglfs's native "virtual desktop" is exposed, however from some preliminary testing said virtual desktop completely breaks input field focusing, has wonky mouse cursor clamping behavior, and seemingly even causes the theme to fail to load properly
   - additionally, nice-to-haves like different DPIs per screen are fundamentally incompatible with its architecture
   - this might be addressed by shipping a minimal Wayland compositor in the SDDM closure to properly support multi-monitor scenarios (maybe automatically sourcing monitor configuration data from `kwinoutputconfig.json` as well)
 - the closure size could be reduced even further by stripping unreferenced dynamic libraries from the closure
 - some KMS modules (*cough cough* NVIDIA) pretty much ship the entire driver stack already; maybe we can fully use the GPU and not rely on SW rendering for those (would need to trim down `nvidia-x11` somehow tho)