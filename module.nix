# NixOS module: quiet fan curve for the GMKtec M5 PLUS (ITE IT5570E EC).
#
# The fan on this board is driven entirely by EC firmware; there is no hwmon
# PWM and no ACPI fan object. This module rewrites the EC's own fan curve
# table, which the firmware then keeps enforcing. See README.md for the
# reverse-engineered register map.
#
# Usage:
#   imports = [ ./module.nix ];
#   hardware.gmktecFanControl.enable = true;

{ config, lib, pkgs, ... }:

let
  cfg = config.hardware.gmktecFanControl;
  csv = vals: lib.concatStringsSep "," (map toString vals);
in
{
  options.hardware.gmktecFanControl = {
    enable = lib.mkEnableOption "GMKtec M5 PLUS (IT5570E) fan curve control";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "The gmktec-fanctl package to use.";
    };

    duties = lib.mkOption {
      type = lib.types.listOf (lib.types.ints.between 0 255);
      default = [ 25 32 40 50 105 183 ];
      description = ''
        PWM duty (0-255) for fan curve levels 1 through 6. The factory values
        are [ 45 54 73 91 118 183 ].

        Level 4 covers everything up to 74 C, so on a machine that idles near
        70 C it is the step that runs permanently, and lowering it is what
        removes the noise. Level 6 defaults to the stock value so the fan still
        ramps fully above 96 C.

        Approximate duty to rpm on the M5 PLUS 40 mm fan:
        10:295 20:499 30:731 40:1177 50:1517 60:1806 75:2268 91:2703
        110:3107 130:3594 160:4161.
      '';
    };

    tempBounds = lib.mkOption {
      type = lib.types.listOf (lib.types.ints.between 0 120);
      default = [ 54 61 64 74 96 ];
      description = ''
        Upper CPU temperature bound, in degrees Celsius, for curve levels 1
        through 5. Level 6 is the top step and has no bound. Defaults are the
        factory values; raising a bound widens the temperature band that the
        corresponding (quieter) level covers.
      '';
    };

    reapplyInterval = lib.mkOption {
      type = lib.types.str;
      default = "60s";
      example = "5min";
      description = ''
        How often to re-write the curve, as a systemd time span. The table
        lives in volatile EC SRAM and the firmware restores factory values on
        events such as resume from suspend, so it is re-applied periodically.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.length cfg.duties == 6;
        message = "hardware.gmktecFanControl.duties must have exactly 6 entries (levels 1-6).";
      }
      {
        assertion = builtins.length cfg.tempBounds == 5;
        message = "hardware.gmktecFanControl.tempBounds must have exactly 5 entries (levels 1-5).";
      }
      {
        assertion = lib.lists.sort (a: b: a < b) cfg.tempBounds == cfg.tempBounds;
        message = "hardware.gmktecFanControl.tempBounds must be in ascending order.";
      }
    ];

    environment.systemPackages = [ cfg.package ];

    systemd.services.gmktec-fan-control = {
      description = "Apply quiet fan curve to the IT5570E EC (GMKtec M5 PLUS)";
      documentation = [ "https://github.com/huynhduc9905/gmktec-m5-fan-control" ];
      # The EC reloads its factory table on resume, so run again on wake.
      after = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" ];
      wantedBy = [
        "multi-user.target"
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart =
          "${cfg.package}/bin/gmktec-fanctl apply --quiet "
          + "--duties ${csv cfg.duties} --bounds ${csv cfg.tempBounds}";
      };
    };

    systemd.timers.gmktec-fan-control = {
      description = "Periodically re-apply the IT5570E fan curve";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15s";
        OnUnitActiveSec = cfg.reapplyInterval;
        Unit = "gmktec-fan-control.service";
      };
    };
  };
}
