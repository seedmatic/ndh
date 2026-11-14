# docs

## OVERVIEW
AsciiDoc documentation only (36 files). Specs, runbooks, architecture, catalogs.

## STRUCTURE
Flat docs/*.adoc + sessions/ subdir. README.adoc is index.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Spec | *-spec.adoc |
| Runbook | *-runbook.adoc |
| Architecture | *-architecture.adoc, *-topology-c4.adoc |
| Catalog | *-catalog*.adoc |
| Session notes | sessions/ |

## CONVENTIONS
- AsciiDoc only; no Markdown.
- Kebab-case filenames with role suffix.
- README.adoc groups docs by domain.

## ANTI-PATTERNS
- Don't add .md files here.
## NOTES
- sessions/ holds per-session notes.
- README.adoc is the doc index.
- Keep specs updated with code.
- No generated docs in src.
