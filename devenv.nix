{pkgs, ...}: {
  # https://devenv.sh/packages/
  packages = with pkgs; [
    git
    alejandra
    nixd
  ];

  # https://devenv.sh/languages/
  languages.lua.enable = true;
}
