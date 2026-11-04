# Home Manager module for a single user-owned ZeroClaw daemon.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    types
    mkEnableOption
    mkIf
    mkOption
    mkPackageOption
    literalExpression
    optionalAttrs
    ;

  cfg = config.programs.zeroclaw;
  tomlFormat = pkgs.formats.toml { };

  effectiveSettings =
    if cfg.webUiPackage == null || lib.hasAttrByPath [ "gateway" "web_dist_dir" ] cfg.settings then
      cfg.settings
    else
      lib.recursiveUpdate cfg.settings {
        gateway.web_dist_dir = "${cfg.webUiPackage}/share/zeroclaw-web";
      };

  mergedSettings = lib.recursiveUpdate effectiveSettings (
    if cfg.extraConfig == "" then { } else builtins.fromTOML cfg.extraConfig
  );
  configFile = tomlFormat.generate "zeroclaw-config.toml" mergedSettings;
  resolveConfig = pkgs.writeShellApplication {
    name = "zeroclaw-resolve-config";
    runtimeInputs = [ pkgs.envsubst ];
    text = ''
      set -euo pipefail
      mkdir -p ${lib.escapeShellArg cfg.dataDir}
      tmp=${lib.escapeShellArg "${cfg.dataDir}/.config.toml.tmp"}
      envsubst < ${configFile} > "$tmp"
      if [ ! -s "$tmp" ]; then
        echo "zeroclaw: rendered config.toml is empty after envsubst" >&2
        rm -f "$tmp"
        exit 1
      fi
      chmod 0600 "$tmp"
      mv -f "$tmp" ${lib.escapeShellArg "${cfg.dataDir}/config.toml"}
    '';
  };
in
{
  options.programs.zeroclaw = {
    enable = mkEnableOption "the ZeroClaw daemon";

    package = mkPackageOption pkgs "zeroclaw" { };

    webUiPackage = mkOption {
      type = types.nullOr types.package;
      default = pkgs.zeroclaw-web or null;
      defaultText = literalExpression "pkgs.zeroclaw-web";
      description = ''
        Web dashboard bundle. When set, the module defaults
        `settings.gateway.web_dist_dir` to the bundle's static files unless
        that setting is provided explicitly. Set to `null` to skip this
        package-derived default.
      '';
    };

    dataDir = mkOption {
      type = types.path;
      default = "${config.home.homeDirectory}/.zeroclaw";
      defaultText = literalExpression ''"''${config.home.homeDirectory}/.zeroclaw"'';
      description = "Directory containing ZeroClaw's rendered configuration and state.";
    };

    settings = mkOption {
      type = types.submodule { freeformType = tomlFormat.type; };
      default = { };
      example = literalExpression ''
        {
          schema_version = 4;
          providers.models.anthropic.default.model = "claude-sonnet-4-6";
        }
      '';
      description = "ZeroClaw configuration rendered as TOML.";
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/agenix/zeroclaw.env";
      description = "EnvironmentFile loaded by the user service for secrets and settings substitution.";
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Raw TOML parsed and deep-merged over settings.";
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ cfg.package ];

    systemd.user.services.zeroclaw = {
      Unit = {
        Description = "ZeroClaw agent";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
        X-StopIfChanged = false;
      } // optionalAttrs (cfg.environmentFile != null) {
        ConditionPathExists = cfg.environmentFile;
      };
      Service = {
        Type = "simple";
        Environment = [
          "ZEROCLAW_CONFIG_DIR=${cfg.dataDir}"
          "ZEROCLAW_WORKSPACE=${cfg.dataDir}/workspace"
        ];
        ExecStartPre = lib.getExe resolveConfig;
        ExecStart = "${lib.getExe cfg.package} daemon";
        WorkingDirectory = cfg.dataDir;
        Restart = "on-failure";
        RestartSec = "5s";
        EnvironmentFile = mkIf (cfg.environmentFile != null) [ cfg.environmentFile ];
        UMask = "0077";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}