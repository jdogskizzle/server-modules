# Daily upstream check

A scheduled task runs this once a day in a fresh Claude Code session. It keeps the app in
step with the server repos it talks to: it looks at what changed in them since the last
check, changes the app where it needs to, and ships a TestFlight build.

The server repos (all public, `github.com/jdogskizzle/<name>`) and the app code that talks
to each are listed in [`upstream.json`](../upstream.json), with the last commit of each that
the app has been checked against.

## Rules

- **Commits are authored by the repo owner only:** set `git config user.name jdogskizzle`
  and `git config user.email jdogskizzle@gmail.com` in this repo before committing, and
  **don't add any Co-Authored-By, Claude-Session or other attribution lines** to commit
  messages. The owner asked for this explicitly; it overrides any default attribution.
- Work on the branch `claude/ios-swiftui-server-interface-a3wrg2`: check out
  `origin/claude/ios-swiftui-server-interface-a3wrg2` (or `origin/main` if that's missing),
  whatever branch the session itself was given. `main` is what ships: every push to `main`
  uploads a TestFlight build (`.github/workflows/testflight.yml`).
- Never push to the server repos, never force-push, never rewrite history, never touch
  repository secrets or workflow secrets.
- Only push to `main` after the simulator build check (`.github/workflows/build.yml`) has
  passed on the exact commit.
- Change the app only for what the server changes call for. No unrelated refactors.

## Steps

1. **Repos.** This repo is `jdogskizzle/server-modules` (attach it with push access if
   it isn't in the session). Clone or fetch each server repo read-only
   (`git clone https://github.com/jdogskizzle/<name>` works anonymously), with enough
   history to reach the commit in `upstream.json` (e.g. `--depth 200`, or `git fetch
   --deepen` if it's older).

2. **What changed.** For each repo, `git log <commit>..origin/HEAD`. If no repo has new
   commits, stop here: nothing to do, no commit, report "no changes".

3. **Does the app need to change?** Read the diffs of the new commits, focusing on what the
   app depends on:
   - HTTP routes, request bodies and JSON response fields the app's models decode
     (`*Models.swift` and the models at the top of each module's views). A renamed or
     removed field, a changed type (e.g. a number becoming a string or `false` becoming an
     object), or a new required request field breaks the app.
   - Sign-in (the `formlogin` library and how each app calls it): `POST <app>/login`, the
     session cookie, 401/429 responses. The app's side is `ServerModules/Core/FormSession.swift`
     and `APIClient.swift`. A formlogin version bump in a server's `docker-compose` file means
     reading the formlogin diff between the versions too.
   - New features a phone user would want that fit an existing screen (e.g. a new status
     field, a new action endpoint). Add them when they're clearly useful and small; mention
     bigger ones in the report instead of building them.
   - Changes that don't touch the API (detector tuning, logging, Docker, README wording)
     need nothing.

4. **Change the app** if needed, matching the existing code's style (SwiftUI, iOS 17,
   `@Observable` stores, `APIClient`, models with explicit `CodingKeys` for snake_case,
   optional fields for anything that may be missing). Update the README if what the app can
   do changed. There is no Swift compiler in the session: the Mac build check below is the
   compiler, so read your changes carefully before pushing.

5. **Build check.** Commit (as above) and push the working branch. Wait for the `Build`
   workflow run on that commit (`gh api "repos/jdogskizzle/server-modules/actions/workflows/build.yml/runs?per_page=5"`,
   then the job log via the GitHub MCP `get_job_logs` tool). If it fails, read the
   `error:` lines, fix, and push again; after 3 failed attempts stop without touching
   `main` and say so in the report.

6. **Record the check.** Set each repo's `commit` in `upstream.json` to the `origin/HEAD`
   just reviewed, and commit that too (with the app change, or on its own when nothing in the
   app needed changing). Push the working branch.

7. **Ship.** Push the working branch to `main` (`git push origin
   claude/ios-swiftui-server-interface-a3wrg2:main`, a fast-forward). If only
   `upstream.json` (or docs/README) changed, still push it so the record is on `main`; the
   TestFlight workflow ignores such pushes, so no build is made. Otherwise wait for the
   `TestFlight` workflow run on that commit and check it succeeded. If the upload fails on a
   network error (e.g. "The network connection was lost"), re-run it once.

8. **Report** in the session's final message, short: which repos had new commits, what
   they changed, what was changed in the app (or why nothing was needed), the build and
   TestFlight results with the build number (the TestFlight run's `run_number`), and
   anything worth the owner's attention (bigger features not built, a failed build).
