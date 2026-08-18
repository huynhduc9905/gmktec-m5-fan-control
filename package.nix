{ lib, stdenvNoCC, python3 }:

stdenvNoCC.mkDerivation {
  pname = "gmktec-fanctl";
  version = "0.1.0";

  src = ./.;

  dontBuild = true;
  dontConfigure = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 gmktec-fanctl "$out/bin/gmktec-fanctl"
    substituteInPlace "$out/bin/gmktec-fanctl" \
      --replace '#!/usr/bin/env python3' '#!${python3.interpreter}'
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    "$out/bin/gmktec-fanctl" --help > /dev/null
  '';

  meta = with lib; {
    description = "Fan curve control for the ITE IT5570E EC on the GMKtec M5 PLUS";
    homepage = "https://github.com/huynhduc9905/gmktec-m5-fan-control";
    license = licenses.gpl2Only;
    platforms = [ "x86_64-linux" ];
    mainProgram = "gmktec-fanctl";
  };
}
