{ pkgs ? import <nixpkgs> {} }:

(pkgs.buildFHSEnv {
 name = "bazel";
 targetPkgs = pkgs: [
   pkgs.bazelisk
   pkgs.just
 ];
}).env
