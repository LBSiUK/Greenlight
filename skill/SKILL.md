---
name: greenlight
description: Use when the user types /greenlight (with a list of tasks or on its own), asks to "greenlight" a set of changes, or a background `greenlight wait` command finishes. For changes the user must sign off twice, on the plan and on a localhost build, before any pull request.
---

# Greenlight

The user signs off every change twice, in the Greenlight Mac app: first the plan, then the
built change running on localhost. You plan, build and open pull requests. Their clicks decide
when you move on. **Never build before a greenlight, and never open a pull request before an
accept.** Skip a gate only when the user tells you to in so many words, then record what they
decided with `greenlight set` so the app matches.

Run `greenlight help` for the commands. If `greenlight` is not on PATH, use
`/Applications/Greenlight.app/Contents/MacOS/Greenlight`. Records live in
`~/Library/Application Support/Greenlight`. Change them only through the command. Every command
works from the repo or any of its worktrees.

| Stage | Who acts | You |
|---|---|---|
| planning | you | plan with subagents, publish the plan |
| review | user | wait |
| redlit | you | → replanning, ask what to change, revise, → review |
| greenlit | you | → building, build, serve, → qa |
| qa | user | wait |
| denied | you | → fixing, ask what is wrong, fix, → qa |
| accepted | you | → shipping, open the PR, → done |

A change is **visual** when it changes layout, colour, imagery or components. A wording fix is not visual.

## 1. `/greenlight <tasks>`

1. The project is the git repo you are in. If you are not in one, ask which project. Run `open -a Greenlight`.
2. One task = one change = one branch = one PR, split the way the user wrote them. If a task can be read two ways, ask one question.
3. Run `greenlight new "<batch title>"` to get a batch number and a plan folder. The folder is `.greenlight/<batch>` in the repo, and git ignores it. Then run `greenlight add <batch> "<title>" --summary "<one line>"` for each task, adding `--visual` for visual ones.
4. If any change is visual and the project has a dev server, make a base worktree first: `git fetch`, then `git worktree add ../<repo>-greenlight/base origin/<default branch>`. Install its dependencies and start one dev server there for all the planners to share (see the localhosts skill). Never use the user's own checkout.
5. Plan in parallel: send one `general-purpose` subagent per change, all in one message. Each brief gives:
   - the task word for word, the repo path, and the change number
   - "Read the code. Do not change the repo. Write files only in `<plan folder>/<id>/`."
   - for visual changes: the dev server URL and the picture recipe below
   - what to return: the approach in plain words, the files to change, the tests to add, any risks or questions for the user, and the paths of the pictures
6. Write the plan page at `<plan folder>/index.html`. Start with Artifact `quickstart` (intent `other`) and follow its page guidance. The CLAUDE.md design-skill rules apply to building the changes, not to this page. It is one page for the batch, with one section per change, each with `id="change-<id>"`. Each section shows the title, the approach, the files, and the risks or questions. Visual changes show before and after side by side, at desktop and phone size. Publish it as an Artifact, with the pictures in `files`.
7. Run `greenlight plan <batch> <artifact url>`. This puts the changes up for review in the app. Stop the planners' server and remove the base worktree.
8. Start listening: run `greenlight wait` in Bash with `run_in_background: true`.
9. Tell the user in two lines: the plan link, and that each change is waiting for a greenlight or redlight in the app. Then stop.

**Picture recipe for planners:** open your own browser session with `playwright-cli -s=gl-<id> open <url>`. For "before", screenshot the real page at 1440×900 and 390×844. For "after", apply the change live in the browser (DOM or CSS edits through `eval`, with nothing written to the repo) and screenshot it at the same sizes. If that cannot show the change (a new page, a native app), draw an HTML mockup with the project's real colours, fonts and spacing, and label it "mockup". Close your session when done.

## 2. When `greenlight wait` finishes

| Exit code | Meaning | Do |
|---|---|---|
| 0 | it printed the calls the user made | handle each one, as below |
| 3 | nothing is open in this repo | stop listening |
| 4 | `--timeout` ran out | start it again |
| 5 | another `wait` is already listening | nothing; that one will report |

Before anything else, move each change to its working stage, or the next `wait` will return it again:

- **redlit**: run `greenlight set <id> --stage replanning`. Check the plan Artifact's comments (Artifact `comments`) for a note on that section, then ask what to change, one question at a time. Once you have the answer, revise the plan: continue the planner with SendMessage if it ran in this session, otherwise send a new one with the old section and the feedback. Keep the link: republish the same file path, or in a later session pass the plan URL from `greenlight show <id>` as `url` (Artifact `read` it first). Then run `greenlight set <id> --stage review`.
- **greenlit**: run `greenlight set <id> --stage building`, then build it (section 3).
- **denied**: run `greenlight set <id> --stage fixing`, then ask what is wrong. Fix it in the same worktree, check it again (section 3, steps 4–5), then run `greenlight set <id> --stage qa`.
- **accepted**: run `greenlight set <id> --stage shipping`, then open the PR (section 4).

Ask when it is convenient. If you are partway through a step, finish that step first. Never abandon a build to ask.
**Before every turn ends, run `greenlight wait` in the background** so the user's next click is heard. If one is already listening, it exits with code 5, which is fine.

## 3. Building a greenlit change

1. Make one worktree per change: `git fetch`, then `git worktree add ../<repo>-greenlight/<id> -b greenlight/<id>-<slug> origin/<default branch>`. Install its dependencies. Run `greenlight set <id> --branch <branch>`.
2. Send one build subagent per greenlit change, in parallel, so you stay free to answer the user. Brief each one with its plan section word for word, the worktree path, and: "Build it properly. Follow the repo's CLAUDE.md (including its design-skill rules for UI work), add tests, run the tests and the type check, commit on the branch, and don't push." Commits follow the repo's attribution rules in memory. Some repos take no Claude attribution lines.
3. When a builder reports back, you do the rest yourself.
4. Serve the change from its worktree on its own port (localhosts skill: a background server, then `localhosts add <port> --label "<repo>: #<id> <title>"`). If the change has no web UI (a CLI, library or native app), write `<plan folder>/<id>/qa/index.html` instead and serve it with `python3 -m http.server <port>`. The page says what changed, how to try it, the test output and the diff.
5. Check it yourself before the user sees it: open it in a browser at phone and desktop width and read the console.
6. Run `greenlight set <id> --stage qa --qa http://localhost:<port>/<path>`, then tell the user in one line that it is ready to test.

Keep no more than three dev servers running at once. If you have to restart a server, use the same port if you can. If the port changes, run `greenlight set <id> --qa <new url>`.

## 4. Opening the pull request

1. If there is no GitHub remote, or the repo's memory says to work another way (for example, commit straight to main), ask before you push anything.
2. From the worktree, run `git push -u origin <branch>`, then `gh pr create --base <default branch>`. The PR body covers what changed and why, a link to the change's plan section, and how it was tested.
3. Run `greenlight set <id> --stage done --pr <url>`. If the user had it shipped another way, run `greenlight set <id> --stage done` with no `--pr`. Then stop the change's server (`localhosts stop <port>`) and run `git worktree remove`. Keep the branch.
4. Give the user the PR link in one line.

## `/greenlight` on its own

This resumes the work:

1. Run `greenlight list`. Use `greenlight show <id>` for a change's branch, links and plan URL.
2. Handle anything waiting on you (section 2). Changes in `building`, `fixing`, `replanning` or `shipping` were left half-done by an earlier session, so check their worktree and finish them.
3. If a change is in `qa` but its server is gone (`localhosts list`), restart it from its worktree.
4. Start `greenlight wait`, then give a short status.
5. If the user gave tasks earlier in the conversation that are not in Greenlight yet, ask whether to start a batch with them.

If the user decides in chat instead of the app ("greenlight 14", "drop 15"), record it with `greenlight set <id> --stage greenlit` (or `dropped`).

## Common mistakes

| Mistake | What happens | Do instead |
|---|---|---|
| Ending a turn without `greenlight wait` running | the user's clicks go unheard; the app shows "Claude isn't listening" | run it before every turn ends |
| Running `wait` again before moving the change to its working stage | `wait` returns the same change straight away, in a loop | run `set --stage …` first |
| Building or fixing a change without a greenlight because it is "tiny" | skips the user's gate | plan it like any other change, unless the user said to skip |
| Republishing a revised plan without its old path or URL | a new link, and the app points to the old plan | same file path, or `url` from `greenlight show` |
| Branching a worktree from the current HEAD | the change carries unrelated local work | base it on `origin/<default branch>` |
| Planners editing the repo or sharing a browser session | a dirty tree and mixed-up screenshots | keep planners read-only; one `-s=gl-<id>` session each |
| Moving a change to qa without opening it yourself | the user tests a broken page | check phone and desktop width and the console first |
