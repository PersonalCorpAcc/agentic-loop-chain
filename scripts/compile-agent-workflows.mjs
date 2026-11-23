// Managed by @software-factory-dev/cli@0.5.1. Source: loops/scripts/compile-agent-workflows.mjs. Profile digest: ede943dfa18d. Update with `workflows update --force`; consumer edits may be overwritten.

const OPENCODE_VERSION = '1.18.23'
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const workflowDirectory = existsSync("loops/workflows") ? "loops/workflows" : ".github/workflows";

// On Windows, `gh` resolves to a shim that spawnSync cannot find without a shell.
// Resolve the full path via `where` so spawnSync works with shell: false (security-safe).
// Prefer an executable: a script named `gh` earlier on PATH (a bash wrapper, say) is listed
// first, and spawnSync cannot run a script without a shell.
function resolveGhPath() {
  if (process.platform !== "win32") return "gh";
  const result = spawnSync("where", ["gh"], { encoding: "utf8", shell: false });
  if (result.status === 0) {
    const found = result.stdout.split("\n").map((s) => s.trim()).filter(Boolean);
    const chosen = found.find((path) => /\.exe$/i.test(path)) ?? found[0];
    if (chosen) return chosen;
  }
  return "gh";
}

// gh-aw folds a workflow's top-level `if:` into the activation job but computes activation.needs
// on its own, so a compiled `if:` can read `needs.<job>` for a job activation never waits for.
// GitHub does not reject that: the reference resolves to '' at runtime and the clause is silently
// true (agent-merge-gate's protected_changes guard, Pliny-Bot run 34042143350). actionlint would
// flag it, but it is deliberately not run on generated files (it does not model concurrency.queue
// or job.workflow_*). This is the one check that reads the locks, and it needs no dependency:
// gh-aw emits jobs at two spaces, job keys at four, list items at six.
function undeclaredNeeds(lock) {
  const violations = [];
  let inJobs = false;
  let job = null;
  let inList = false;
  let jobs = 0;
  let needs = new Set();
  let refs = new Set();
  const flush = () => {
    if (!job) return;
    for (const ref of refs) if (!needs.has(ref)) violations.push({ job, ref, needs: [...needs].sort() });
  };
  for (const line of lock.split("\n")) {
    if (/^jobs:\s*$/.test(line)) { inJobs = true; continue; }
    if (inJobs && /^[^\s#]/.test(line)) inJobs = false;
    if (!inJobs) continue;
    const start = line.match(/^  ([a-z_][a-zA-Z0-9_-]*):\s*$/);
    if (start) { flush(); job = start[1]; jobs += 1; needs = new Set(); refs = new Set(); inList = false; continue; }
    if (!job) continue;
    if (/^    needs:\s*$/.test(line)) { inList = true; continue; }
    const inline = line.match(/^    needs:\s*(.+?)\s*$/);
    if (inline) {
      for (const n of inline[1].replace(/[\[\]]/g, "").split(",")) if (n.trim()) needs.add(n.trim());
      inList = false;
      continue;
    }
    if (inList) {
      const item = line.match(/^      - (\S+)\s*$/);
      if (item) { needs.add(item[1]); continue; }
      inList = false;
    }
    for (const m of line.matchAll(/needs\.([a-z_][a-zA-Z0-9_-]*)\./g)) refs.add(m[1]);
  }
  flush();
  return { jobs, violations };
}

const compile = spawnSync(resolveGhPath(), ["aw", "compile", "--strict", "--dir", workflowDirectory], {
  stdio: "inherit",
  shell: false,
});

if (compile.error?.code === "ENOENT" || compile.status === null) {
  process.stderr.write("Could not run `gh aw compile`. Install githubnext/gh-aw first.\n");
  process.exit(1);
}

if (compile.status !== 0) process.exit(compile.status ?? 1);

function lintLock(file, text) {
  const lint = undeclaredNeeds(text);
  if (lint.jobs === 0) {
    process.stderr.write(
      `${file}: the needs lint found no jobs; the gh-aw lock layout changed. ` +
      `Re-anchor undeclaredNeeds() in loops/scripts/compile-agent-workflows.mjs.\n`,
    );
    process.exitCode = 1;
  }
  for (const v of lint.violations) {
    process.stderr.write(
      `${file}: job "${v.job}" reads needs.${v.ref} but its needs are [${v.needs.join(", ")}]; ` +
      `the reference resolves to '' at runtime. For activation, list the job under on.needs in the ` +
      `source frontmatter; for a custom job, add it to that job's needs.\n`,
    );
    process.exitCode = 1;
  }
}

// gh aw compile leaves a lock alone when its frontmatter and body hashes still match the source.
// This script then ran over a lock it had already patched: AGENTMEMORY_URL was inserted a second
// time, the opencode install line was wrapped in itself, and the consumer freshness check could
// never be clean (Pliny-Bot agentics-checks run 33963600563). The sentinel marks a processed
// lock; a lock that carries it is linted and otherwise left as it is.
const SENTINEL = "# post-processed by scripts/compile-agent-workflows.mjs; run it again and nothing changes";

// Every rewrite this script makes to gh-aw's compiled output, as a table (FR-035, review WF-09).
// Each was a silent failure once; a gh-aw upgrade that reshapes its anchor brings the failure
// back without a word, because a `.replace` that finds nothing is not an error. So each row says
// which locks it must match, and the compile fails when it does not:
//   when: "always"        every agent lock, whatever the engine
//   when: ["opencode"]    every lock compiled for one of these engines
//   when: "conditional"   only locks that carry what it fixes (a stack's setup step, a mode
//                         gh-aw picks by itself), so a miss proves nothing and is only reported
// `upstream` names the gh-aw behaviour the row works around, for the issue that retires it.
// COMPILE_REWRITE_REPORT=1 prints which row matched which lock.
// Checked against gh-aw main on 23/11/2026 (v1.3.1): the rows marked "after v0.87.5" are fixed
// upstream and go when the pin moves (T111); the claude harness's retry is filed as gh-aw #80341.
// Retired 23/11/2026, matching nothing at v0.87.5 on either engine: building agent_output.json
// from safeoutputs.jsonl over the placeholder's {"items":[]} (the placeholder now writes only when
// the file is missing, which the "placeholder step intact" check below holds it to).
const REWRITES = [
  {
    id: "sentinel",
    when: "always",
    upstream: null,
    apply: (t) => t.replace(/^(# This file was automatically generated by gh-aw[^\n]*\n)/m, `$1${SENTINEL}\n`),
  },
  {
    // The agent's own debug log fills the job log and buries the failure.
    id: "opencode log level",
    when: ["opencode"],
    upstream: "the opencode engine runs with --print-logs --log-level DEBUG and no switch turns it down",
    apply: (t) => t
      .replaceAll("opencode run --print-logs --log-level DEBUG", "opencode run --log-level ERROR")
      .replaceAll("opencode run --print-logs --log-level ERROR", "opencode run --log-level ERROR")
      .replaceAll("--log-level DEBUG", "--log-level ERROR"),
  },
  {
    id: "model info",
    when: "always",
    upstream: null,
    apply: (t) => t
      .replace(/GH_AW_INFO_MODEL: "[^"]*"/g, 'GH_AW_INFO_MODEL: "per-agent"')
      .replace(/OPENCODE_MODEL: [^\n]+/g, "OPENCODE_MODEL: ''")
      .replace(/GH_AW_INFO_MODEL_COSTS: '[^']*'/g, 'GH_AW_INFO_MODEL_COSTS: \'{"providers":{}}\''),
  },
  {
    // gh-aw defaults NPM_CONFIG_MIN_RELEASE_AGE to 3 days, which blocks any package
    // published in the last three days with ETARGET "No matching version found ... with a
    // date before". Lowered to 1 so a fix released yesterday is usable. This is a
    // supply-chain cooldown: shortening it accepts a newer package sooner.
    id: "npm release age",
    when: ["opencode"],
    upstream: "NPM_CONFIG_MIN_RELEASE_AGE is fixed at 3 days with no frontmatter override",
    apply: (t) => t.replace(/NPM_CONFIG_MIN_RELEASE_AGE: ['\"]?3['\"]?/g, "NPM_CONFIG_MIN_RELEASE_AGE: '1'"),
  },
  {
    // The MCP gateway runs inside a per-runner Docker-in-Docker daemon. gh-aw publishes it on
    // 127.0.0.1, which is the DinD container's own loopback, while the outer publish forwards to
    // that container's eth0, so the two never meet and gh-aw's health check fails 120 times with
    // ECONNREFUSED. Binding 0.0.0.0 inside the daemon connects them. The host still exposes the
    // port on loopback only, because the DinD container is published as 127.0.0.1:<port>.
    id: "MCP gateway bind",
    when: "always",
    upstream: "the MCP gateway publishes on 127.0.0.1, unreachable from the outer publish under Docker-in-Docker",
    apply: (t) => t.replaceAll("-p 127.0.0.1:'\"${MCP_GATEWAY_PORT}\"':", "-p '\"${MCP_GATEWAY_PORT}\"':"),
  },
  {
    // awf chroots into the Docker daemon's filesystem and requires it to be the runner's own
    // glibc host. A Docker-in-Docker daemon fails with "Detected Alpine/musl host filesystem
    // under /host", and no dind image fixes it: the agent needs the runner's toolchain and
    // workspace, which a separate daemon container never has. So every agent job shares one
    // daemon, awf's container names (awf-agent, awf-squid, awf-api-proxy) are fixed, and the
    // jobs on one host must be serialised: two would recreate each other's containers and the
    // first dies with exit 137. The lock lives outside the /tmp/gh-aw namespace on purpose.
    id: "awf host lock",
    when: "always",
    upstream: "awf's container names are fixed, so two agent jobs on one host collide",
    apply: (t) => t.replaceAll('          awf --config', '          flock /tmp/agentic-awf.lock awf --config'),
  },
  {
    // Each runner needs its own gateway port: runners on one host publish to one loopback, so
    // two jobs on 8080 would collide. The runner sets it in its .env.
    id: "MCP gateway port",
    when: "always",
    upstream: "MCP_GATEWAY_PORT is exported as a fixed 8080",
    apply: (t) => t.replaceAll('export MCP_GATEWAY_PORT="8080"', 'export MCP_GATEWAY_PORT="${MCP_GATEWAY_PORT:-8080}"'),
  },
  {
    // The "Copy Safe Outputs" step runs on the host after the awf container exits. At that
    // point /tmp/gh-aw/ IS the host's /tmp/gh-aw/, where the safeoutputs MCP container wrote
    // patch and bundle files (via the MCP gateway's -v /tmp:/tmp:rw mount). Extend the step
    // to also copy those files to RUNNER_TEMP/gh-aw/ so the upload step can include them.
    // Without this, the upload step's glob /tmp/gh-aw/aw-*.patch runs inside the awf chroot
    // (where /tmp/gh-aw is a different path) and finds nothing. The safe_outputs and conclude
    // jobs then receive no patches in the artifact and silently skip the push.
    id: "copy patches and bundles",
    when: "always",
    upstream: "the agent artifact omits the safe-outputs container's aw-*.patch and aw-*.bundle files",
    apply: (t) => t.replace(
      '          cp "$GH_AW_SAFE_OUTPUTS" /tmp/gh-aw/safeoutputs.jsonl 2>/dev/null || true\n',
      '          cp "$GH_AW_SAFE_OUTPUTS" /tmp/gh-aw/safeoutputs.jsonl 2>/dev/null || true\n' +
      '          # Copy patch/bundle files generated by the safeoutputs MCP container to\n' +
      '          # RUNNER_TEMP/gh-aw/ so the upload step includes them in the artifact.\n' +
      '          mkdir -p "${RUNNER_TEMP}/gh-aw"\n' +
      '          ls -la /tmp/gh-aw/ 2>/dev/null || true\n' +
      '          cp /tmp/gh-aw/aw-*.patch "${RUNNER_TEMP}/gh-aw/" 2>/dev/null || true\n' +
      '          cp /tmp/gh-aw/aw-*.bundle "${RUNNER_TEMP}/gh-aw/" 2>/dev/null || true\n' +
      '          ls -la "${RUNNER_TEMP}/gh-aw/"aw-* 2>/dev/null || true\n'),
  },
  {
    // Add patch/bundle paths to the upload glob so the agent artifact carries what
    // push-agent-branch needs. The anchor is the two adjacent path lines of the
    // "...agent" upload step; the "...agent-output-fallback" upload lists them in the
    // opposite order, so it cannot match. Anchoring matters: the first bare
    // '/tmp/gh-aw/agent_output.json\n' in the file is the placeholder step's echo line,
    // and replacing there corrupted the placeholder into executing the globs as
    // commands while the upload list stayed without bundles. The artifact then carried
    // no bundle, push-agent-branch silently skipped the push, and the gate reported
    // "remediated" on a pull request that was never touched.
    // Only the /tmp/gh-aw globs may be added: a ${{ runner.temp }} path as well would
    // move the upload's least-common-ancestor from /tmp/gh-aw to /, and every file in
    // the artifact (agent_output.json included) would gain a prefix that
    // download-agent-output does not look for.
    id: "bundle upload glob",
    when: "always",
    upstream: "the agent artifact omits the safe-outputs container's aw-*.patch and aw-*.bundle files",
    apply: (t) => t.replace(
      '            /tmp/gh-aw/safeoutputs.jsonl\n            /tmp/gh-aw/agent_output.json\n',
      '            /tmp/gh-aw/safeoutputs.jsonl\n' +
      '            /tmp/gh-aw/aw-*.patch\n' +
      '            /tmp/gh-aw/aw-*.bundle\n' +
      '            /tmp/gh-aw/agent_output.json\n'),
  },
  {
    // "A failed run is already a red run": report-failure-as-issue: false and
    // GH_AW_REPORT_FAILED_JOBS: "false" were supposed to silence issue creation, but
    // 0.87.5's engine-failure reporter files an "[aw] ... failed" issue anyway (seen as
    // Pliny-Bot #57: an OOM-killed gate produced a fresh issue nobody needs, while the
    // retry belt is the actual remediation). `if: false` keeps the step compiled but
    // never runs it, so the failure stays visible in the run and in the belt's attempt
    // comment, and out of the issue tracker.
    id: "failed-jobs reporter off",
    when: "always",
    upstream: "report-failure-as-issue: false does not stop the report_failed_jobs step filing an issue; after v0.87.5, safe-outputs.report-failed-jobs: false does",
    apply: (t) => t.replace(
      /^([ \t]+)- name: Report failed jobs\n([ \t]*)id: report_failed_jobs\n[ \t]*if: always\(\)\n/m,
      '$1- name: Report failed jobs\n$2id: report_failed_jobs\n$2if: false # never: failures surface in the run and the retry belt\n'),
  },
  {
    // Centralised AgentMemory: an always-on service; the shim proxies to it when the URL is
    // set and authenticates with the HMAC secret. Local development leaves both unset and
    // keeps the local per-run store.
    id: "memory URL",
    when: "always",
    upstream: null,
  },
  {
    // the secret is scoped to the one step that runs the agent (semgrep: a secret in
    // workflow-level env is visible to every job and step)
    id: "memory secret beside the agent step",
    when: ["opencode"],
    upstream: null,
  },
  {
    // the router passes secrets explicitly (semgrep flags secrets: inherit as over-broad),
    // so the callee must declare everything it accepts
    id: "memory secret declared",
    when: "always",
    upstream: null,
  },
  {
    // v0.87.5's arc-dind mode stages the engine CLI to a daemon-visible path but assumes the
    // Copilot engine: command -v copilot is empty under engine: opencode and cp "" fails the
    // job before the agent starts. OpenCode needs no staging, because npm -g installs it under
    // the tool-cache prefix inside _work, which the dind daemon shares.
    id: "copilot staging skipped",
    when: "conditional",
    upstream: "arc-dind mode stages the copilot binary whatever the engine (related: gh-aw #76973)",
    apply: (t) => t.replaceAll('          COPILOT_SRC="$(command -v copilot)"',
      '          command -v copilot >/dev/null 2>&1 || { echo "no copilot binary (engine is opencode); skipping"; exit 0; }' + '\n' +
      '          COPILOT_SRC="$(command -v copilot)"'),
  },
  {
    // gh-aw hardcodes a second reporter (report_failed_jobs) that files an "[aw] Failed jobs"
    // issue per red run. Same philosophy as the row above, same off switch.
    id: "failed-jobs env off",
    when: "always",
    upstream: "GH_AW_REPORT_FAILED_JOBS is set true whatever report-failure-as-issue says; after v0.87.5, safe-outputs.report-failed-jobs: false",
    apply: (t) => t.replaceAll('GH_AW_REPORT_FAILED_JOBS: "true"', 'GH_AW_REPORT_FAILED_JOBS: "false"'),
  },
  {
    // gh-aw sees a custom step calling dotnet and injects its own setup-dotnet, which carries
    // no DOTNET_INSTALL_DIR and so tries to write /usr/share/dotnet. The runner user has no
    // sudo, so the job dies with "Permission denied" before the agent starts. The shared
    // baseline step already redirects to the tool cache; this gives every other one the same
    // env, including ones a future gh-aw release injects.
    id: "setup-dotnet install dir",
    when: "conditional",
    upstream: "the injected setup-dotnet step has no DOTNET_INSTALL_DIR and writes /usr/share/dotnet",
    apply: (t) => t.replace(
      /^( +)- name: Setup \.NET\n\1  uses: actions\/setup-dotnet@[^\n]*\n\1  with:\n((?:\1    [^\n]*\n)+)(?!\1  env:)/gm,
      (_m, indent, withBody) =>
        indent + '- name: Setup .NET\n' + indent + '  uses: actions/setup-dotnet@a98b56852c35b8e3190ac28c8c2271da59106c68 # v6.0.0\n' +
        indent + '  with:\n' + withBody +
        indent + '  env:\n' + indent + '    DOTNET_INSTALL_DIR: ${{ runner.tool_cache }}/dotnet\n'),
  },
  {
    // gh-aw pins opencode-ai 1.2.14 at every release checked, up to v0.87.5, from 25/02/2026.
    // The harness expects 1.18, so a gh-aw upgrade does not move it and the pin is ours.
    id: "opencode version",
    when: ["opencode"],
    upstream: "the opencode engine pins opencode-ai 1.2.14",
    apply: (t) => t.replace(/opencode-ai@[0-9][0-9.]*/g, 'opencode-ai@' + OPENCODE_VERSION),
  },
  {
    // gh-aw installs with --ignore-scripts, which blocks opencode's own postinstall. That
    // script downloads the platform binary, so 1.18 fails at first use with "opencode-ai's
    // postinstall script was not run". Run only opencode's postinstall explicitly, so every
    // other package's scripts stay blocked; install only when the pinned version is missing,
    // under a lock so two jobs starting at once cannot both write the global prefix.
    id: "opencode install",
    when: ["opencode"],
    upstream: "npm install --ignore-scripts skips opencode-ai's postinstall, which fetches its binary (gh-aw #50114, closed after v0.87.5)",
    apply: (t) => t.replace(
      /npm install --ignore-scripts -g opencode-ai@([0-9][0-9.]*)/g,
      (_m, v) =>
        "opencode --version 2>/dev/null | grep -qF '" + v + "' || " +
        "flock /tmp/opencode-install.lock sh -c 'npm install --ignore-scripts -g opencode-ai@" + v +
        " && cd \"$(npm root -g)/opencode-ai\" && node postinstall.mjs' # opencode-ai@" + v),
  },
  {
    // One warm server per runner, on its own port, with its own data directory. Keyed on the
    // runner rather than the run so a runner keeps its server warm between its own jobs.
    // No double quotes here: the enclosing run: is a double-quoted YAML scalar.
    id: "opencode data per runner",
    when: ["opencode"],
    upstream: "the opencode server's data directory is one fixed path per host",
    apply: (t) => t.replace(/\/tmp\/opencode-data(?!-\$\{\{)/g, () => '/tmp/opencode-data-${{ runner.name }}'),
  },
];

const expectedIn = (rewrite, engine) =>
  rewrite.when === "always" || (Array.isArray(rewrite.when) && rewrite.when.includes(engine));
const rewriteTally = [];
process.on("exit", () => {
  if (process.env.COMPILE_REWRITE_REPORT !== "1") return;
  for (const rewrite of REWRITES) {
    const rows = rewriteTally.filter((row) => row.id === rewrite.id);
    const hit = rows.filter((row) => row.matched).map((row) => `${row.file.replace(/\.lock\.yml$/, "")}(${row.engine})`);
    process.stderr.write(`rewrite ${JSON.stringify(rewrite.id)} [${Array.isArray(rewrite.when) ? rewrite.when.join(",") : rewrite.when}]: ${hit.length}/${rows.length} ${hit.join(" ")}\n`);
  }
});

for (const file of readdirSync(workflowDirectory)) {
  if (!file.endsWith(".lock.yml")) continue;

  const path = join(workflowDirectory, file);
  const content = readFileSync(path, "utf8");
  if (content.includes(SENTINEL)) {
    lintLock(file, content);
    continue;
  }
  // Which engine compiled this lock decides which rewrites it must carry (see REWRITES).
  const engine = /GH_AW_INFO_ENGINE_ID: "([a-z]+)"/.exec(content)?.[1] ?? "unknown";
  let patched = content;
  for (const rewrite of REWRITES) {
    // Install drops a line whose optional profile value is unset, `apply` included: the memory
    // rows vanish for a repository with no central memory, which is the row opting out.
    if (typeof rewrite.apply !== "function") continue;
    const after = rewrite.apply(patched);
    const matched = after !== patched;
    rewriteTally.push({ id: rewrite.id, file, engine, matched });
    if (!matched && expectedIn(rewrite, engine)) {
      process.stderr.write(
        `compile rewrite "${rewrite.id}" no longer matches in ${file} (engine ${engine}): the gh-aw template changed. ` +
        `Re-anchor it in REWRITES in loops/scripts/compile-agent-workflows.mjs (FR-035).\n`,
      );
      process.exitCode = 1;
    }
    patched = after;
  }

  let rewritten = patched;
  // A queued implement executes hours after its run was created, but actions/checkout
  // without a ref checks out github.sha, which GitHub pins at run creation. Five children
  // queued together at 02:01 all carried the 02:01 base; once the first sibling merged,
  // every later push became a rebase onto a moved parent, which gh-aw's signed-commit
  // push cannot do (it dies with "cannot rebase: You have unstaged changes" and files the
  // pull request as an issue instead of a pull request). Checking out the branch tip at
  // execution time makes the commit parent current main; the implement-global queue
  // already keeps sibling merges out of the window while the agent runs.
  // The branch is the profile's branch point, not the repository default (FR-025): work is
  // cut from the branch point, and under a chain its pull request opens against a different
  // branch, so "whatever the forge calls default" is an answer to neither question.
  if (file === "agent-implement.lock.yml") {
    const start = rewritten.indexOf("\n  agent:\n");
    const rest = start === -1 ? "" : rewritten.slice(start + 1);
    const next = rest.search(/\n  [a-z_][a-zA-Z_-]*:\n/);
    if (start !== -1 && next !== -1) {
      const end = start + 1 + next;
      const span = rewritten.slice(start, end).replace(
        /(uses: actions\/checkout@[^\n]*\n(\s+)with:\n(?:\2  [^\n]+\n)*)/,
        (whole, _block, indent) =>
          whole.includes("ref:") ? whole : whole + indent + "  ref: dev\n",
      );
      rewritten = rewritten.slice(0, start) + span + rewritten.slice(end);
    }
  }

  // Guard the two rewrites the compiled agent jobs cannot work without. The anchors are
  // upstream template text: when a gh-aw upgrade reshapes either step, the silent
  // failure mode returns (an artifact with no bundle, a skipped push, a green gate on
  // an untouched pull request). Failing the compile is the only loud signal there is.
  for (const check of [
    { name: "bundle upload glob", ok: /\n( +)- name: Upload agent artifacts\n\1  if: always\(\)\n\1  continue-on-error: true\n\1  uses: actions\/upload-artifact@[^\n]*\n\1  with:\n\1    name: \$\{\{ needs\.activation\.outputs\.artifact_prefix \}\}agent\n\1    path: \|\n(?:\1      [^\n]*\n)*\1      \/tmp\/gh-aw\/aw-\*\.bundle\n/ },
    { name: "placeholder step intact", ok: /\n( +)- name: Write agent output placeholder if missing\n\1  if: always\(\)\n\1  run: \|\n\1    if \[ ! -f \/tmp\/gh-aw\/agent_output\.json \]; then\n\1      echo '\{"items":\[\]\}' > \/tmp\/gh-aw\/agent_output\.json\n\1    fi\n/ },
    { name: "failed-jobs reporter disabled", ok: /- name: Report failed jobs\n[ \t]*id: report_failed_jobs\n[ \t]*if: false[^\n]*\n/ },
  ]) {
    if (!check.ok.test(rewritten)) {
      process.stderr.write(
        `compile patch "${check.name}" no longer matches in ${file}: the gh-aw template changed. ` +
        `Re-anchor the rewrite in loops/scripts/compile-agent-workflows.mjs, or agent pushes are silently dropped.\n`,
      );
      process.exitCode = 1;
    }
  }

  // gh-aw's create_pull_request.go returns an **empty** handler configuration on any parse
  // failure and the compile still succeeds, so a frontmatter that says `signed-commits:
  // false` proves only that somebody wrote it. Every switch below is one whose default
  // turns a failure into a green run or a silent revert, and the lock is the copy the run
  // reads (FR-052, FR-061). Checked here rather than only in this package's tests, because
  // the consumer compiles too, and the consumer is where a gh-aw upgrade lands first.
  const workerSource = path.replace(/\.lock\.yml$/, ".md");
  const isStaged = existsSync(workerSource) && /^ {2}staged: true$/m.test(readFileSync(workerSource, "utf8"));

  for (const [name, expectations] of Object.entries({
    create_pull_request: {
      required: { signed_commits: false, auto_close_issue: false, preserve_branch_name: true, fallback_as_issue: false },
      absent: ["allowed_base_branches", "recreate_ref"],
      nonEmpty: ["base_branch", "branch_prefix"],
    },
    push_to_pull_request_branch: {
      required: { signed_commits: false, fallback_as_pull_request: false, check_branch_protection: false },
      absent: [],
      nonEmpty: [],
    },
  })) {
    for (const key of ["GH_AW_SAFE_OUTPUTS_CONFIG", "GH_AW_SAFE_OUTPUTS_HANDLER_CONFIG"]) {
      const line = new RegExp(`^ +${key}: "(.*)"$`, "m").exec(rewritten);
      if (line === null) continue;
      let config;
      try {
        config = JSON.parse(line[1].replaceAll('\\"', '"'));
      } catch {
        process.stderr.write(`${file}: ${key} is not parseable JSON, so what the run will read cannot be checked.\n`);
        process.exitCode = 1;
        continue;
      }
      const handler = config[name];
      // A worker that does not use the handler has nothing to get wrong. A worker that
      // does, and whose handler configuration is empty, is exactly the silent failure.
      if (handler === undefined) continue;
      // Except where the handler does not write: a staged worker's outputs are applied by
      // its own conclude job with the App token, so the handler's fallbacks never run and
      // requiring their switches there is a rule with no failure behind it.
      if (name === "push_to_pull_request_branch" && isStaged) continue;
      for (const [setting, expected] of Object.entries(expectations.required)) {
        if (handler[setting] !== expected) {
          process.stderr.write(
            `${file}: ${key}.${name}.${setting} is ${JSON.stringify(handler[setting])}, not ${JSON.stringify(expected)}. ` +
            `The compiler drops the whole configuration on a parse failure and still succeeds, so check the worker's frontmatter for that key (FR-052).\n`,
          );
          process.exitCode = 1;
        }
      }
      for (const setting of expectations.absent) {
        if (setting in handler) {
          process.stderr.write(`${file}: ${key}.${name}.${setting} is set; its absence is the decision (FR-052).\n`);
          process.exitCode = 1;
        }
      }
      for (const setting of expectations.nonEmpty) {
        if (typeof handler[setting] !== "string" || handler[setting] === "") {
          process.stderr.write(`${file}: ${key}.${name}.${setting} is empty; the profile's value did not reach the lock (FR-025, FR-052).\n`);
          process.exitCode = 1;
        }
      }
      if (handler["patch_format"] !== undefined && handler["patch_format"] !== "bundle") {
        process.stderr.write(`${file}: ${key}.${name}.patch_format is ${JSON.stringify(handler["patch_format"])}; only bundle applies fast-forward (research R2).\n`);
        process.exitCode = 1;
      }
    }
  }

  // The memory secret is injected beside OPENAI_BASE_URL because that is the one step
  // that runs the agent (a secret in workflow-level env is visible to every job and step).
  // The rewrite is global, so a lock that grows a second OPENAI_BASE_URL -- a setup step,
  // a second engine block -- would quietly hand the secret to that step too. One
  // occurrence, or the compile fails and says where the other one is.
  {
    const injections = [...rewritten.matchAll(/^ *AGENTMEMORY_SECRET: \$\{\{ secrets\./gm)];
    if (injections.length > 1) {
      const lines = injections.map((match) => rewritten.slice(0, match.index).split("\n").length);
      process.stderr.write(
        `${file}: the memory secret was injected ${injections.length} times, at lines ${lines.join(", ")}. ` +
        `It belongs to the agent step alone; re-anchor the injection in loops/scripts/compile-agent-workflows.mjs.\n`,
      );
      process.exitCode = 1;
    }
  }

  if (!rewritten.includes(SENTINEL)) {
    process.stderr.write(
      `${file}: the generated-file header changed and the post-processing sentinel was not placed; ` +
      `re-anchor the SENTINEL insert in loops/scripts/compile-agent-workflows.mjs.\n`,
    );
    process.exitCode = 1;
  }
  lintLock(file, rewritten);

  if (rewritten !== content) writeFileSync(path, rewritten);
}
