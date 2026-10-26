# NicuQuestions

## Shared tooling (source of truth: BenCohen1988/OpsScripts)

The rules that apply to every repo live in one place and are not copied here:

- **Skills**: `dev-team` (`dev-team-project` in a Claude Project), `code-change-rules`, `auto-format`,
  `model-router`, `repo-docs`. Source in `OpsScripts/skills/`, reaching Claude
  Code sessions as the plugin `ops-skills@opsscripts` (OpsScripts README,
  `skills/`). `ponytail` is the upstream
  plugin (`ponytail@ponytail`), enabled in `.claude/settings.json` so it updates
  itself; standard-check fails settings that drop it. Follow `code-change-rules`
  on every change; run `dev-team` for anything bigger than a one-file fix.
- **Formatter hook**: `.claude/scripts/format.sh` and `formatters.sh` (the
  pinned formatter versions) are byte-identical copies of
  `OpsScripts/skills/auto-format/scripts/`. `.claude/settings.json`
  runs it after every Edit/Write, `.githooks/pre-commit` on every commit
  (`git config core.hooksPath .githooks` once per clone). Never edit the copy
  here: change it in OpsScripts, then copy it over.
- **CI** is OpsScripts' shared workflows, called from `.github/workflows/`;
  change the steps there, and only triggers, paths and floors here.
- **English only**: everything in the repo is English except what the app
  shows its users; the pre-commit hook and CI enforce it.
- **Dependencies, Theme and Constants**: a type takes one nested `Dependencies`, built
  at the composition root; colors and fonts come only from the theme
  (`App/Theme.swift`, or one CSS file on the web); a screen's own values
  and texts sit in a private, nested constants block at the top of its
  type (`private enum Constants` in Swift), never as literals in the body.
- **Files**: one topic per file, named for it, in a fixed order (header,
  `Constants`, `Dependencies`, state, init, public API, private helpers).
- **Structure**: Redux for state and Rx (Combine in Swift) for events
  wherever they fit; folders by feature; files under 300 lines; no
  duplication (CI annotates both); no empty `catch`.
- **What this repo never formats** is declared in `.gitattributes` with
  `-format`, not in the script.

## This repo's own rules

(add them below this line, not to OpsScripts)

- The site is `index.html` alone, served by GitHub Pages from `main`
  (https://bencohen1988.github.io/NicuQuestions/). It is a static page with
  no build step; the app's text is Hebrew and stays Hebrew.
- The question bank is the `rawQuestions` array in it:
  `[topic 1-5, difficulty 1-3, question, correct, wrong1, wrong2, wrong3,
explanation]`, plus an optional ninth field (1 = written by Claude, 2 =
  recalled from a past exam). `guards/question-bank.test.js` checks that shape.
- A question's id is a hash of its text: reword one and add the old -> new
  pair to `ID_ALIASES`, or saved progress for it is lost.
- This repo is public: never commit course materials, PDFs or exam photos.
- CI runs on GitHub's runners, not the Oracle VM, because the repo is public.
