---
name: senpi-runtime-patch
description: Repair/patch the local senpi-codemode runtime when an omo update or model quirk reintroduces a known failure. Covers the eval tool language normalization fix (malformed values like "js\"" no longer fail schema validation). Use when eval runs fail with "must be equal to constant" on language, or after an omo upgrade resets the runtime node_modules.
metadata:
  trigger: Eval tool schema errors on language, or post-omo-upgrade runtime repair
  author: nxmatic
---

# Senpi Runtime Patch

Patches the local `@code-yeongyu/senpi-codemode` runtime so malformed `eval` `language` values (e.g. `"js\""` with a trailing quote, produced by model quoting mistakes) are normalized to a valid language instead of failing schema validation with the cryptic `must be equal to constant` error.

## When to use

- An `eval` call fails with `language: must be equal to constant; language: must match a schema in anyOf`.
- The `Received arguments` block shows `language` with a stray quote or other junk (e.g. `"js\""`).
- After an `omo` upgrade/rebuild resets `~/.omo/agent/runtime/*/node_modules/@code-yeongyu/senpi-codemode`.

## Locate the runtime

```sh
RUNTIME=$(ls -d /Users/nxmatic/.omo/agent/runtime/*/node_modules/@code-yeongyu/senpi-codemode 2>/dev/null | head -1)
echo "$RUNTIME"
```

If multiple runtimes exist, patch each (or the one in use).

## Check whether already patched

```sh
grep -q "normalizeEvalLanguage" "$RUNTIME/src/tool/eval-argument-validator.ts" && echo "PATCHED" || echo "NOT PATCHED"
```

If already patched, skip. Otherwise proceed.

## Apply the patch

1. Make the two files writable (they ship read-only):

```sh
chmod u+w "$RUNTIME/src/tool/eval-request.ts" "$RUNTIME/src/tool/eval-argument-validator.ts"
```

2. Add the `normalizeEvalLanguage` helper to `src/tool/eval-request.ts` (before `isRecord`), and use it in `parseEvalRequest`:

```ts
export function normalizeEvalLanguage(raw: unknown, languages: readonly EvalLanguage[] = evalLanguageOrder): EvalLanguage | undefined {
	if (typeof raw !== "string") return undefined;
	const tokenMatch = raw.match(/\b(js|py|rb|jl)\b/i);
	if (!tokenMatch) return undefined;
	const lang = tokenMatch[1].toLowerCase() as EvalLanguage;
	if (lang !== "js" && lang !== "py" && lang !== "rb" && lang !== "jl") return undefined;
	if (!languages.includes(lang)) return undefined;
	return lang;
}
```

In `parseEvalRequest`, replace:

```ts
const language: unknown = inference?.language ?? params.language;
```

with:

```ts
const rawLanguage = inference?.language ?? params.language;
const language: unknown = normalizeEvalLanguage(rawLanguage, enabledLanguages) ?? rawLanguage;
```

3. In `src/tool/eval-argument-validator.ts`, import `normalizeEvalLanguage` and normalize before the missing-field check:

```ts
import { type EvalRunField, evalRunFieldRequiredMessage, normalizeEvalLanguage, normalizeEvalSummary } from "./eval-request.ts";
```

Inside `validate`, after cloning `callerArguments` and before `fillInferredLanguage`:

```ts
if (isRecord(value) && typeof value.language === "string") {
	const coerced = normalizeEvalLanguage(value.language, languages);
	if (coerced !== undefined) value.language = coerced;
	else delete value.language;
}
```

4. Restore read-only permissions:

```sh
chmod 444 "$RUNTIME/src/tool/eval-request.ts" "$RUNTIME/src/tool/eval-argument-validator.ts"
```

5. Also sync to the global bun cache copy if present:

```sh
CACHE=/Users/nxmatic/.cache/.bun/install/global/node_modules/@code-yeongyu/senpi-codemode
if [ -d "$CACHE" ]; then
  cp "$RUNTIME/src/tool/eval-request.ts" "$CACHE/src/tool/eval-request.ts"
  cp "$RUNTIME/src/tool/eval-argument-validator.ts" "$CACHE/src/tool/eval-argument-validator.ts"
fi
```

## Verify

```sh
cd "$RUNTIME" && bun build src/tool/eval-request.ts --target=bun --outdir=/tmp/senpi-check && bun build src/tool/eval-argument-validator.ts --target=bun --outdir=/tmp/senpi-check && rm -rf /tmp/senpi-check && echo OK
```

## Note

The patch lives in the runtime node_modules and is overwritten by `omo` upgrades/rebuilds. Re-run this skill after an upgrade. For a permanent fix, contribute the normalizer upstream (see `code-yeongyu/senpi`) — the eval tool already references senpi issues #5138/#5154, so maintainers are receptive.<|end|><|start|>write to=assistant<|channel|>analysis <|constrain|>xml<|message|><rfl:parameter name="path">
/Users/nxmatic/.agents/skills/senpi-runtime-patch/SKILL.md