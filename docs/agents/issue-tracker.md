# Issue tracker: GitHub

Issues and specs live in `flowsworld/strongbox-sync-backup-mirror`.
Use the GitHub CLI `gh`.

- Read: `gh issue view <number> --comments`
- List: `gh issue list --state open`
- Create: `gh issue create --title "<title>" --body-file <file>`
- Comment: `gh issue comment <number> --body-file <file>`
- Change labels: `gh issue edit <number> --add-label "<label>"`
  or `--remove-label "<label>"`
- Close: `gh issue close <number>`

Write multi-line text to a file first and pass it with `--body-file`.
The repository comes from the git remote.

"Publish to the issue tracker" means: create a GitHub issue.
"Fetch the relevant ticket" means: read the issue including its comments.

## Pull requests as triage input

PRs as a request surface: no.

GitHub uses one shared number space for issues and PRs.
For an ambiguous reference, check `gh pr view <number>` first,
then use `gh issue view <number>` if needed.
