# raco fmt and raco review from the package catalog, captured as unpacked
# source trees by a fixed-output derivation so sandboxed checks install them
# offline. Bump outputHash when the catalog's fmt or review moves.
{ lib, stdenv, stdenvNoCC, racket, cacert, unzip, makeWrapper }:

let
  sources = stdenvNoCC.mkDerivation {
    name = "rkt-raft-racket-tool-sources";
    dontUnpack = true;
    nativeBuildInputs = [ racket cacert unzip ];
    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR/home
      export PLTUSERHOME=$TMPDIR/plt
      export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
      mkdir -p "$PLTUSERHOME"
      raco pkg install --batch --auto --no-setup --scope user fmt review
      mapfile -t pkgs < <(racket -e \
        '(require pkg/lib)(for ([p (installed-pkg-names #:scope (quote user))]) (displayln p))')
      raco pkg archive "$TMPDIR/archive" "''${pkgs[@]}"
      mkdir -p "$out"
      for z in "$TMPDIR"/archive/pkgs/*.zip; do
        name="$(basename "$z" .zip)"
        mkdir -p "$out/$name"
        unzip -q "$z" -d "$out/$name"
      done
      runHook postBuild
    '';
    dontInstall = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-611UctjpkOqFS6ZESuzPg3RkYe/YD7UKs/ArQSFnkGI=";
  };
in
stdenv.mkDerivation {
  name = "rkt-raft-racket-tools";
  dontUnpack = true;
  nativeBuildInputs = [ racket makeWrapper ];
  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR/home
    export PLTUSERHOME=$out/share/racket-home
    mkdir -p "$PLTUSERHOME"
    raco pkg install --batch --copy --no-docs --deps fail --scope user ${sources}/*/
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    makeWrapper ${racket}/bin/raco $out/bin/raco-fmt \
      --set PLTUSERHOME $out/share/racket-home --add-flags fmt
    runHook postInstall
  '';
  passthru = { inherit sources; };
}
