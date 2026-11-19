inputs: final: prev: {
  # a2a-sdk: litellm (claude/providers.nix) pulls a2a-sdk via its proxy extras.
  # a2a-sdk 0.3.26 is not cached on aarch64-darwin 26.05, so it builds from
  # source and its checkPhase fails: two e2e tests in
  # tests/e2e/push_notifications/ error with
  #   AttributeError: Can't get local object 'FastAPI.setup.<locals>.openapi'
  # — a FastAPI-internals incompatibility (821 pass, 2 error), not a real
  # regression. Disable checkPhase. Overriding the python313 set here is cheap:
  # verified via `darwin-rebuild build --dry-run` that only a2a-sdk and its
  # reverse-dep litellm rebuild (the fixed-point override does NOT mass-rebuild
  # the set on 26.05) — and litellm already builds from source anyway (its
  # streaming-firsttoken patch in claude/providers.nix busts its cache).
  #
  # Removal: drop once nixpkgs marks the e2e tests broken on darwin / bumps
  # a2a-sdk to a FastAPI-compatible release, or once a2a-sdk is cached.
  python313 = prev.python313.override {
    packageOverrides = pyfinal: pyprev: {
      a2a-sdk = pyprev.a2a-sdk.overridePythonAttrs (_: {
        doCheck = false;
      });
      expression = pyfinal.buildPythonPackage {
        pname = "expression";
        version = "5.6.0";
        format = "wheel";
        src = prev.fetchurl {
          url = "https://files.pythonhosted.org/packages/6b/a2/656b8bebe495117342a8676ccabf52b3885ce11a856c8dfe1fbbdc250d2d/expression-5.6.0-py3-none-any.whl";
          hash = "sha256-9cYuOBhskofgiN7pzzk5sLveIctMWVcYchVKU9M918A=";
        };
        dependencies = [ pyfinal.typing-extensions ];
        doCheck = false;
      };
      litellm = pyprev.litellm.overridePythonAttrs (
        old:
        let
          wheels = {
            aarch64-darwin = {
              url = "https://files.pythonhosted.org/packages/52/55/82e0ddb4ac036e29882f15b62a34a120b399059fb4da8d2eb8312f906832/litellm-1.110.0-cp310-abi3-macosx_11_0_arm64.whl";
              hash = "sha256-vIT2fhjonjmZaEQ3jB6ASK6qSeO7uThV3wzgT5f2QDg=";
            };
            aarch64-linux = {
              url = "https://files.pythonhosted.org/packages/71/61/a2ab3353b8b5c9e68482200873628a1df813bb617af62b9c2450d9952b8e/litellm-1.110.0-cp310-abi3-manylinux_2_28_aarch64.whl";
              hash = "sha256-mXc4iOjdDQuEL8ivp4617XoLMcE/Gy0KEYzwQjvF24w=";
            };
            x86_64-linux = {
              url = "https://files.pythonhosted.org/packages/5b/21/b502e48603205b9482f4cb5403556600c7aa6dc77bd336bb79b4ba0c67d2/litellm-1.110.0-cp310-abi3-manylinux_2_28_x86_64.whl";
              hash = "sha256-Jx41dB+KlE7kv6vzE0LtzQU4W90gqThtGcCFyy5NxQc=";
            };
          };
        in
        {
          version = "1.110.0";
          format = "wheel";
          pyproject = null;
          src = prev.fetchurl wheels.${prev.stdenv.hostPlatform.system};
          build-system = [ ];
          postPatch = "";
          patches = [ ];
          nativeBuildInputs = [ ];
          buildInputs = [ prev.stdenv.cc.cc.lib ];
          dontCheckRuntimeDeps = true;
          env.LITELLM_LOCAL_MODEL_COST_MAP = "True";
          dependencies =
            (old.dependencies or [ ])
            ++ (with pyfinal; [
              h2
              filelock
              packaging
              huggingface-hub
              anyio
              pydantic-settings
              boto3
              certifi
              typing-extensions
              pyyaml
            ]);
          optional-dependencies = (old.optional-dependencies or { }) // {
            proxy =
              (old.optional-dependencies.proxy or [ ])
              ++ (with pyfinal; [
                httpx2
                httpcore2
                granian
                starlette
                hiredis
                inquirerpy
                tomlkit
                semver
                backports-zstd
                expression
              ]);
          };
        }
      );
    };
  };
}
