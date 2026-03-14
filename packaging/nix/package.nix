{
  lib,
  stdenvNoCC,
  fetchurl,
  testers,
}:

let
  versions = lib.importJSON ./versions.json;
  platformKey = stdenvNoCC.hostPlatform.system;
  versionInfo =
    versions.${platformKey}
      or (throw "sql-pipe: unsupported platform '${platformKey}'");
in

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "sql-pipe";
  inherit (versionInfo) version;

  src = fetchurl {
    inherit (versionInfo) url sha256;
  };

  # The release assets are raw binaries (not archives)
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  # Linux binaries are statically linked via musl — no dynamic linker to
  # patch, no libraries to strip.  macOS binaries are self-contained.
  dontStrip = true;
  dontPatchELF = true;
  dontFixup = stdenvNoCC.hostPlatform.isLinux;

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/sql-pipe
    runHook postInstall
  '';

  passthru = {
    updateScript = ./update.sh;
    tests.version = testers.testVersion {
      package = finalAttrs.finalPackage;
      command = "sql-pipe --version";
    };
  };

  meta = {
    description = "Read CSV from stdin, query with SQL, write CSV to stdout";
    homepage = "https://github.com/vmvarela/sql-pipe";
    changelog = "https://github.com/vmvarela/sql-pipe/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mit;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    mainProgram = "sql-pipe";
    platforms = builtins.attrNames versions;
  };
})
