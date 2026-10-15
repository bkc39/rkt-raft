{ racketTools }:
{ ... }:
{
  projectRootFile = "flake.nix";

  programs.clang-format.enable = true;
  programs.clang-format.includes = [
    "*.c"
    "*.h"
    "*.cpp"
    "*.hpp"
    "*.cu"
    "*.cuh"
  ];
  programs.nixfmt.enable = true;
  programs.shfmt.enable = true;
  programs.shfmt.indent_size = 2;
  settings.formatter.shfmt.options = [ "-ci" ];
  programs.ruff-format.enable = true;

  programs.shellcheck.enable = true;
  programs.actionlint.enable = true;
  programs.ruff-check.enable = true;

  settings.formatter.raco-fmt = {
    command = "${racketTools}/bin/raco-fmt";
    options = [ "-i" ];
    includes = [ "*.rkt" ];
  };

  settings.global.excludes = [
    "LICENSE"
    "flake.lock"
    "plans/*"
    "*.scrbl"
    "*.rktd"
    "*.md"
    ".clang-format"
    ".clang-tidy"
    ".github/actionlint.yaml"
    ".gitignore"
    "*.txt"
    "*.cmake"
    "*.json"
  ];
}
