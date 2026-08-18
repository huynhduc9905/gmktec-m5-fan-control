{
  description = "Fan curve control for the ITE IT5570E EC on the GMKtec M5 PLUS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      packages.${system} = rec {
        gmktec-fanctl = pkgs.callPackage ./package.nix { };
        default = gmktec-fanctl;
      };

      nixosModules = rec {
        gmktecFanControl = import ./module.nix;
        default = gmktecFanControl;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [ pkgs.python3 pkgs.lm_sensors pkgs.acpica-tools ];
      };

      formatter.${system} = pkgs.nixpkgs-fmt;
    };
}
