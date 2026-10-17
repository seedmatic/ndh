{ buildGoModule, lib }:

buildGoModule {
  pname = "ndh-nix-signing-derive";
  version = "1.0.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./go.mod
      ./go.sum
      ./main.go
      ./main_test.go
    ];
  };

  vendorHash = "sha256-5winUnT92P4mv2+ax1C+RbpyxH9vn3b2B98bqaawuGI=";

  ldflags = [
    "-s"
    "-w"
  ];

  # The known vector, the label separation, the secret carrying the public, and the refusals.
  doCheck = true;

  meta = {
    description = "Derive a builder's nix signing key from its ssh host key (HKDF-SHA256, roles × keys B2)";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    mainProgram = "ndh-nix-signing-derive";
  };
}
