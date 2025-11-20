# pdf

macOS CLI PDF reader for LLM agents. Focused on predictable, page-delimited text output and machine-readable search results.

## Install

```bash
swift build -c release
# binary at .build/release/pdf
```

## Commands

- `pdf text <file>` — stream page text (optionally select pages).
- `pdf search <file>` — grep-like search with keywords or regex, optional JSON output.

## Common flags (agents will care about these)

`text`
- `-p, --pages 1,4-6`  limit pages (1-based, ranges allowed)
- `--no-headers`       suppress `--- PAGE N ---`
- `--show-count`       print `pageCount=<n>` before content

`search` (alias: `filter`)
- `-t, --term foo,bar` one or more terms (comma or repeated flag)
- `--terms-file path`  load terms from file (newline or comma separated)
- `--regex`            treat terms as regex patterns
- `--case-sensitive`   match with case sensitivity (default is case-insensitive)
- `-p, --pages ...`    restrict pages
- `--context N`        include N lines before/after each match
- `--format text|json` machine-friendly JSON or human text (default: text)
- `--max-matches N`    stop after N total matches
- `--no-defaults`      disable built‑in APFS-ish defaults
- `--no-headers`       suppress `--- PAGE N ---` in text mode

### LLM-friendly help

Every subcommand accepts `--llm-help` to emit a deterministic, JSON-formatted schema of its arguments and options for tool-using agents.

## Shell completions

Generate a completion script for your shell (bash, zsh, fish) and install it in your shell’s fpath/completions dir:

```bash
# zsh example
swift run pdf completions zsh > /usr/local/share/zsh/site-functions/_pdf
autoload -Uz compinit && compinit

# bash example
swift run pdf completions bash > /usr/local/share/bash-completion/completions/pdf

# fish example
swift run pdf completions fish > ~/.config/fish/completions/pdf.fish
```

## Examples

```bash
# dump whole doc
pdf text spec.pdf

# only pages 10-20 with headers
pdf text spec.pdf -p 10-20

# search with custom keywords and JSON output
pdf search spec.pdf \
  --term "snapshot" --term "checkpoint,rollback" \
  --format json --context 1 --max-matches 50

# use regex patterns from a file
pdf search spec.pdf --terms-file patterns.txt --regex --format json
```

## License

MIT Copyright (c) 2025 **blacktop**
