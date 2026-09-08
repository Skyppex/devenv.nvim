{pkgs, ...}: {
  # https://devenv.sh/packages/
  packages = with pkgs; [
    stylua
    git
    alejandra
    nixd
  ];

  # https://devenv.sh/languages/
  languages.lua.enable = true;

  services = {
    postgres = {
      enable = true;
      listen_addresses = "127.0.0.1";
    };

    redis.enable = true;

    rabbitmq = {
      enable = true;
      managementPlugin.enable = true;
    };
  };
}
