{
  lib,
  stdenv,
  meson,
  ninja,
  pkg-config,
  bison,
  flex,
  python3Packages,
  libxml2,
  libllvm,
  libdrm,
  libgbm,
  libglvnd,
  mesa,
}:
stdenv.mkDerivation {
  name = "mesa-minimal";
  inherit (mesa) version src;

  mesonAutoFeatures = "disabled";
  mesonFlags = [
    "--sysconfdir=/etc"

    (lib.mesonBool "opengl" true)
    (lib.mesonEnable "gles1" false)
    (lib.mesonEnable "gles2" false)
    (lib.mesonEnable "egl" true)
    (lib.mesonEnable "glx" false)

    (lib.mesonEnable "gbm" true)
    (lib.mesonBool "libgbm-external" true)

    (lib.mesonEnable "llvm" true)
    (lib.mesonEnable "glvnd" true)
    (lib.mesonEnable "zlib" false)

    (lib.mesonOption "platforms" "")
    (lib.mesonOption "gallium-drivers" "llvmpipe")
    (lib.mesonOption "vulkan-drivers" "")
    (lib.mesonOption "vulkan-layers" "")
    (lib.mesonOption "egl-native-platform" "drm")
  ];

  buildInputs = [libxml2 libllvm libdrm libgbm libglvnd];
  nativeBuildInputs = [
    meson
    ninja
    pkg-config
    bison
    flex
    python3Packages.packaging
    python3Packages.python
    python3Packages.mako
    python3Packages.pyyaml
  ];
  disallowedReferences = [libllvm];

  postFixup = ''
    # set full path in EGL driver manifest
    for js in $out/share/glvnd/egl_vendor.d/*.json; do
      substituteInPlace "$js" --replace-fail '"libEGL_' '"'"$out/lib/libEGL_"
    done
  '';
}
