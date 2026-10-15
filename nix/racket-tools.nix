# raco fmt and raco review, and fmt's pretty-expressive, each pinned by git
# commit (the catalog's own source for the package). `.fmt.rkt` uses fmt's
# internals, so a bump of fmt or pretty-expressive is a deliberate change:
# move the rev, update the hash, and re-check `.fmt.rkt` against the new fmt.
{
  stdenv,
  runCommand,
  fetchFromGitHub,
  racket,
  makeWrapper,
}:

let
  fmt = fetchFromGitHub {
    owner = "sorawee";
    repo = "fmt";
    rev = "4e1ed68e596e656960b44a8244bb33eb4e65ec64";
    hash = "sha256-zwcjNvK2qcKfsXb2mlQQNOHI2niMMPI9wx9YeEz+XTo=";
  };
  review = fetchFromGitHub {
    owner = "Bogdanp";
    repo = "racket-review";
    rev = "ecb1968f12b485b5387f66bbd9220f191d136d84";
    hash = "sha256-odbHFCxRHvLDrt+j/3qqIbeyK3lscxqSfcSt6xh0Vl4=";
  };
  prettyExpressive = fetchFromGitHub {
    owner = "sorawee";
    repo = "pretty-expressive";
    rev = "27e7be8016b38252a19f3620bc37539100b02503";
    hash = "sha256-BdwzCrufLrYrYQm3OCIOUWMgpUQGYmmsHf7CWNYLarY=";
  };

  sources = runCommand "rkt-raft-racket-tool-sources" { } ''
    mkdir -p $out
    cp -r ${fmt} $out/fmt
    cp -r ${review} $out/review
    cp -r ${prettyExpressive}/pretty-expressive $out/pretty-expressive
    cp -r ${prettyExpressive}/pretty-expressive-lib $out/pretty-expressive-lib
    chmod -R u+w $out
  '';
in
stdenv.mkDerivation {
  name = "rkt-raft-racket-tools";
  dontUnpack = true;
  nativeBuildInputs = [
    racket
    makeWrapper
  ];
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
