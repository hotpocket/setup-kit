# setup-kit — TODOs

Open work for the setup-kit repo.

- [ ] Derive `GIT_HOME` once instead of hardcoding `$HOME/git`. `profiles/workstation/08-claude-skills.sh` names `$HOME/git/gstack` and `$HOME/git/.configs` eleven times (after ac9e59d), `components/gstack.md` once; the global conduct rule (`~/.claude/CLAUDE.md`, "`~/git` is a hardcoded absolute in disguise") says `GIT_HOME="${GIT_HOME:-$(dirname "$THIS_REPO")}"`. This repo has no `GIT_HOME` convention yet, so this introduces it — decide where the one definition lives (a shared `lib/` sourced by every phase, or `bookshelf/repos.yml` as the rule names) before touching the seven sites. Verify with a fresh-VM install where the repos are not under `~/git`.
- [ ] Reconcile `manifests/dock.list` with the live dock: verify.sh reports 2 manifest pins absent (OBS Studio, tts_client) and 3 live pins not in the manifest (Settings, Rhythmbox, baobab). One decision per app on which side is right; then either edit the manifest or run the dock phase in install mode.
