{
  lib,
  stdenv,
  stdenvNoCC,
  fetchFromGitHub,
  makeWrapper,
  coreutils,
  nodejs_22,
  node-gyp,
  python311,
  bun,
  pkg-config,
  anytype-heart,
  libsecret,
  electron,
  go,
  lsof,
  protobuf,
  makeDesktopItem,
  copyDesktopItems,
  writableTmpDirAsHomeHook,
  commandLineArgs ? "",
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "anytype";
  version = "0.55.4";

  src = fetchFromGitHub {
    owner = "anyproto";
    repo = "anytype-ts";
    tag = "v${finalAttrs.version}";
    hash = "sha256-8IGVreAM6LVGL6jp23pl3pEL0EFM7qMvmljBb1cnKbE=";
  };

  locales = fetchFromGitHub {
    owner = "anyproto";
    repo = "l10n-anytype-ts";
    rev = "6ace663582256dc956fd0e0401aa12b323b345bb";
    hash = "sha256-btEJI3DyfWt2O0Sb6FqzbGTHK7lwMt1fXEo6qKDw6BU=";
  };

  node_modules = stdenvNoCC.mkDerivation {
    pname = "${finalAttrs.pname}-node_modules";
    inherit (finalAttrs) version src;

    impureEnvVars = lib.fetchers.proxyImpureEnvVars ++ [
      "GIT_PROXY_COMMAND"
      "SOCKS_SERVER"
    ];

    nativeBuildInputs = [
      bun
      writableTmpDirAsHomeHook
    ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild

      export BUN_INSTALL_CACHE_DIR=$(mktemp -d)
      bun install \
        # https://bun.com/docs/pm/cli/install#configuring-with-environment-variables

        # From docs:
        # Bun always tries to use the fastest available installation method for the target platform. On macOS, that’s clonefile and on Linux, that’s hardlink.
        --backend=copyfile \
        --cpu="*" \
        --frozen-lockfile \
        --ignore-scripts \
        --no-progress \
        --os="*"

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      find . -type d -name node_modules -exec cp -R --parents {} $out \;

      runHook postInstall
    '';

    dontFixup = true;

    outputHash = "sha256-walRZOP+BKgfDwVTi8rDMQFWXLiDR3zlPpYAI9BJO78=";
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
  };

  env = {
    ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
  };

  nativeBuildInputs = [
    bun
    nodejs_22
    pkg-config
    go
    protobuf
    copyDesktopItems
    makeWrapper
    node-gyp
    stdenv.cc
    python311
  ];

  buildInputs = [
    libsecret
  ];

  patches = [
    ./0001-feat-update-Disable-auto-checking-for-updates-and-updating-manually.patch
    ./0002-remove-grpc-devtools.patch
    ./0003-remove-desktop-entry.patch
  ];

  configurePhase = ''
    runHook preConfigure

    cp -R ${finalAttrs.node_modules}/. .
    patchShebangs node_modules

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    # Building keytar against electron's ABI
    # Trying to build in temp dir, will not work duo to the keytar calling the node -p require('node-addon-api').include_dir
    # but building inside the node_modules/keytar will find the ../node-addon-api automaticly
    chmod -R u+w node_modules/keytar node_modules/node-addon-api
    pushd node_modules/keytar
    HOME=$(mktemp -d) node-gyp rebuild --nodedir=${electron.headers}
    popd

    sed -i "s%/usr/bin/env%${coreutils}/bin/env%" scripts/generate-protos.sh

    cp -r ${anytype-heart}/lib dist/
    cp -r ${anytype-heart}/bin/anytypeHelper dist/

    # Without this, build fails when trying to copy/write into that directory during the js bundle step
    chmod -R u+w dist/

    bash ./scripts/generate-protos.sh --from-dist

    bun run build

    for lang in ${finalAttrs.locales}/locales/*; do
      cp "$lang" "dist/lib/json/lang/$(basename $lang)"
    done

    # $HOME/.cache/go-build.
    export GOCACHE=$(mktemp -d)
    # go build -o dist/nativeMessagingHost ./go/nativeMessagingHost.go
    bun run build:nmh

    runHook postBuild
  '';

   # remove unnecessary files
  preInstall = ''
    # npm prune --omit=dev
    chmod u+w -R dist node_modules
    find -type f \( -name "*.ts" -o -name "*.map" \) -exec rm -rf {} +
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/anytype
    cp -r electron.js electron dist node_modules package.json $out/lib/anytype/

    for icon in $out/lib/anytype/electron/img/icons/*.png; do
      mkdir -p "$out/share/icons/hicolor/$(basename $icon .png)/apps"
      ln -s "$icon" "$out/share/icons/hicolor/$(basename $icon .png)/apps/anytype.png"
    done

    cp LICENSE.md $out/share

    makeWrapper '${lib.getExe electron}' $out/bin/anytype \
      --set-default ELECTRON_IS_DEV 0 \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}" \
      --add-flags $out/lib/anytype/ \
      --add-flags ${lib.escapeShellArg commandLineArgs}

    wrapProgram $out/lib/anytype/dist/nativeMessagingHost \
      --prefix PATH : ${lib.makeBinPath [ lsof ]}

    runHook postInstall
  '';

  desktopItems = [
    (makeDesktopItem {
      name = "anytype";
      exec = "anytype %U";
      icon = "anytype";
      desktopName = "Anytype";
      comment = finalAttrs.meta.description;
      mimeTypes = [ "x-scheme-handler/anytype" ];
      categories = [
        "Utility"
        "Office"
        "Calendar"
        "ProjectManagement"
      ];
      startupWMClass = "anytype";
    })
  ];

  passthru.updateScript = ./update.sh;

  meta = {
    description = "P2P note-taking tool";
    homepage = "https://anytype.io/";
    changelog = "https://github.com/anyproto/anytype-ts/releases/tag/${finalAttrs.src.tag}";
    license = lib.licenses.unfreeRedistributable;
    mainProgram = "anytype";
    maintainers = with lib.maintainers; [
      autrimpo
      adda
      kira-bruneau
      xmnlz
    ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
    broken = stdenv.hostPlatform.isDarwin;
  };
})
