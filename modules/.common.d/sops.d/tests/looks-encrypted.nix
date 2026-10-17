# The encrypted-file predicate the evaluation guards share: a YAML sops file passes; a decrypted one, the
# JSON form and a private-key armor do not.
{ pkgs }:
let
  looksEncrypted = import ../looks-encrypted.nix { inherit (pkgs) lib; };
  cases = {
    yamlEncrypted = {
      expect = true;
      content = "token: ENC[AES256_GCM,data:abc,iv:x,tag:y,type:str]\nsops:\n    age:\n        - recipient: age1x\n";
    };
    yamlEncryptedSopsFirst = {
      expect = true;
      content = "sops:\n    version: 3.9.0\nkey: ENC[AES256_GCM,data:abc,type:str]\n";
    };
    decrypted = {
      expect = false;
      content = "token: plain-value\n";
    };
    jsonEncrypted = {
      expect = false;
      content = "{\n\t\"token\": \"ENC[AES256_GCM,data:abc,type:str]\",\n\t\"sops\": {\"age\": []}\n}\n";
    };
    privateArmor = {
      expect = false;
      content = "k: |\n  -----BEGIN OPENSSH PRIVATE KEY-----\n  x\nsops:\n  mac: ENC[x]\n";
    };
  };
  wrong = pkgs.lib.attrNames (
    pkgs.lib.filterAttrs (_: c: looksEncrypted c.content != c.expect) cases
  );
in
assert pkgs.lib.assertMsg (wrong == [ ]) "looks-encrypted misjudges: ${toString wrong}";
pkgs.runCommand "sops-looks-encrypted" { } "touch $out"
