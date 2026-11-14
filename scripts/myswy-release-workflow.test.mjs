// Publish-path invariants for the self-host distribution's release workflow.
//
// These tests do not read the workflow as prose. They extract the actual writer
// commands and job wiring, then replay a rerun scenario against a stand-in for
// the registry and the GitHub release API:
//
//   * the first attempt's guard job succeeded and wrote the verdict to a file;
//   * one writer's step ran to completion and published its tag;
//   * a later step in that same writer failed;
//   * the operator re-runs only the failed jobs — so the guard job does NOT run
//     again, and GitHub replays its stored success;
//   * the writer's steps run again from the top.
//
// The assertion is that the number of write verbs that actually reach the
// registry is zero. A `needs: [guard]` edge cannot satisfy this: it is exactly
// the thing that does not re-execute.
//
// The writers' `run:` blocks are taken from the workflow file itself, with the
// two `uses:`-driven commands (goreleaser, docker/build-push-action) replaced by
// stubs on PATH. Nothing here can reach ghcr.io or github.com.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { parse } from "yaml";

const root = fileURLToPath(new URL("..", import.meta.url));
const readWorkflow = () => parse(readFileSync(join(root, ".github/workflows/release-myswy.yml"), "utf8"));

const TAG = "v0.9.0-myswy.1";
const BACKEND = "multica-backend";
const WEB = "multica-web";

// ---------------------------------------------------------------------------
// Workflow helpers

// Every `run:` block of a job, in order, keeping the step name and `env:` block
// it is executed with — a step's own env is what carries TAG and IMAGE.
function runSteps(job) {
  return (job?.steps ?? [])
    .filter((step) => typeof step.run === "string")
    .map((step) => ({ name: step.name, run: step.run, env: step.env }));
}

// The step whose command performs the actual registry/tag write. Identified by
// the command it runs, not by its name, so renaming a step cannot hide it.
function writerSteps(job, needle) {
  return runSteps(job).filter((step) => step.run.includes(needle));
}

// GitHub Actions interpolates `${{ ... }}` before the shell sees the script.
// Only the expressions these tests need are substituted.
function render(run, vars) {
  return run.replace(/\$\{\{\s*([^}]+?)\s*\}\}/g, (whole, expr) => {
    const key = expr.trim();
    if (key in vars) return String(vars[key]);
    throw new Error(`test cannot render workflow expression: ${whole}`);
  });
}

// ---------------------------------------------------------------------------
// Stub environment

function makeEnv(config) {
  const dir = mkdtempSync(join(tmpdir(), "myswy-release-workflow."));
  const bin = join(dir, "bin");
  mkdirSync(bin);
  const requestLog = join(dir, "requests.log");
  const configPath = join(dir, "config.json");
  const portFile = join(dir, "port");
  writeFileSync(configPath, JSON.stringify(config));

  // Python and the shell built-ins the guard needs must be reachable; the
  // command being stubbed must come first on PATH.
  const python = execFileSync("sh", ["-c", "command -v python3"], { encoding: "utf8" }).trim();

  return { dir, bin, requestLog, configPath, portFile, python };
}

async function startStub(env) {
  const stub = join(root, "scripts/myswy-release-guard-stub.py");
  const child = spawn(env.python, [stub, env.configPath, env.portFile, env.requestLog], {
    stdio: "ignore",
    detached: false,
  });
  for (let i = 0; i < 200; i += 1) {
    if (existsSync(env.portFile) && readFileSync(env.portFile, "utf8").trim() !== "") break;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  const port = readFileSync(env.portFile, "utf8").trim();
  assert.ok(port, "the stub did not report a port");
  return { child, port };
}

// A workflow step's own `env:` block, rendered the way Actions would. The step
// is what carries TAG and IMAGE, so a test that skipped this would be running a
// different script than the workflow does.
function stepEnv(step, vars) {
  const declared = {};
  for (const [key, value] of Object.entries(step.env ?? {})) {
    declared[key] = render(String(value), vars);
  }
  return declared;
}

// Runs one shell script the way a workflow step would: a fresh shell, the
// step's env, and a PATH whose first entry can shadow a command.
function runStep(script, { env, cwd, extraEnv = {} }) {
  return execFileSync("bash", ["-e", "-o", "pipefail", "-c", script], {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      PATH: `${env.bin}:${process.env.PATH}`,
      HOME: env.dir,
      ...extraEnv,
    },
  });
}

// A stub for `docker`: it succeeds, so a write that slips past the guard is
// *counted* rather than blocked. Blocking it would make a bypassing guard look
// identical to a working one — the test would pass either way.
function stubDocker(env) {
  const path = join(env.bin, "docker");
  writeFileSync(
    path,
    `#!/usr/bin/env bash
case " $* " in
  *" imagetools create "*|*" push "*)
    printf 'WRITE docker %s\\n' "$*" >>"${env.requestLog}"
    ;;
esac
exit 0
`,
  );
  chmodSync(path, 0o755);
}

// A stub for `goreleaser`: a published release is a write, and is counted.
function stubGoreleaser(env) {
  const path = join(env.bin, "goreleaser");
  writeFileSync(
    path,
    `#!/usr/bin/env bash
printf 'WRITE goreleaser %s\\n' "$*" >>"${env.requestLog}"
exit 1
`,
  );
  chmodSync(path, 0o755);
}

function writeCount(env) {
  if (!existsSync(env.requestLog)) return 0;
  return readFileSync(env.requestLog, "utf8")
    .split("\n")
    .filter((line) => line.startsWith("WRITE")).length;
}

function requests(env) {
  if (!existsSync(env.requestLog)) return [];
  return readFileSync(env.requestLog, "utf8").split("\n").filter(Boolean);
}

// ---------------------------------------------------------------------------

test("every job that writes a tag re-checks inside itself, in the writing step", () => {
  const workflow = readWorkflow();

  // (a) The merge jobs: the write and the check are the same step, so a rerun of
  // the job cannot reach the push without running the check.
  for (const [jobName, image] of [
    ["docker-backend-merge", BACKEND],
    ["docker-web-merge", WEB],
  ]) {
    const job = workflow.jobs?.[jobName];
    assert.ok(job, `${jobName} must exist`);
    const writers = writerSteps(job, "imagetools create");
    assert.equal(writers.length, 1, `${jobName} must have exactly one manifest-writing step`);
    const run = writers[0].run;
    assert.match(
      run,
      /myswy-release-guard\.sh/,
      `${jobName}'s writing step must run the guard itself: a preceding step can be split off, a\n      guard inside the writing step cannot`,
    );
    assert.match(
      run,
      new RegExp(`--scope image --image ${image}`),
      `${jobName}'s guard must check its own image tag and nothing else`,
    );
    // The guard must come first in the step: a push before the check would be
    // the overwrite this exists to prevent.
    assert.ok(
      run.indexOf("myswy-release-guard.sh") < run.indexOf("imagetools create"),
      `${jobName} must check before it pushes`,
    );
  }

  // (b) The CLI job writes through GoReleaser, so its check is its own step.
  const cli = workflow.jobs?.cli;
  assert.ok(cli, "the cli job must exist");
  const cliRuns = runSteps(cli);
  const checks = cliRuns.filter((step) => step.run.includes("myswy-release-guard.sh"));
  assert.equal(checks.length, 1, "the cli job must run exactly one guard, on purpose-built arguments");
  assert.match(checks[0].run, /--scope release/, "the cli job writes the release, so it checks the release only");
  // GoReleaser is a `uses:` step, so ordering has to be read from the job's full
  // step list, not from the `run:` subset.
  const allSteps = cli.steps ?? [];
  const goreleaserIndex = allSteps.findIndex((step) => String(step.uses ?? "").includes("goreleaser"));
  const guardIndex = allSteps.findIndex((step) => String(step.run ?? "").includes("myswy-release-guard.sh"));
  assert.ok(goreleaserIndex >= 0, "the cli job must still publish through GoReleaser");
  assert.ok(
    guardIndex >= 0 && guardIndex < goreleaserIndex,
    "the cli job must check before GoReleaser writes the release",
  );

  // (c) No writer may depend on the guard's verdict alone. `needs:` is replayed
  // from the earlier attempt on a partial rerun.
  for (const jobName of ["cli", "docker-backend-merge", "docker-web-merge"]) {
    const needs = workflow.jobs?.[jobName]?.needs ?? [];
    const list = Array.isArray(needs) ? needs : [needs];
    assert.ok(
      list.includes("guard"),
      `${jobName} should still run the pre-flight guard before anything is built`,
    );
  }
});

test("only the frozen version tag is published, with no second mutable name", () => {
  const workflow = readWorkflow();

  for (const jobName of ["docker-backend-merge", "docker-web-merge"]) {
    const meta = (workflow.jobs?.[jobName]?.steps ?? []).find((step) => step.id === "meta");
    assert.ok(meta, `${jobName} must compute its tags`);
    const tags = String(meta.with?.tags ?? "");
    assert.match(
      tags,
      /type=raw,value=\$\{\{ needs\.verify\.outputs\.tag_name \}\}/,
      `${jobName} must publish the frozen version tag`,
    );
    // A `sha-*` tag is a second name for the same bytes that a later build of
    // the same commit can repoint; it must not be published at all.
    assert.doesNotMatch(
      tags,
      /type=sha/,
      `${jobName} must not publish a commit-derived tag: the version tag is the only name`,
    );
    assert.match(String(meta.with?.flavor ?? ""), /latest=false/, `${jobName} must not publish latest`);
  }
});

test("the trigger and the verify gate accept exactly vX.Y.Z-myswy.N from this repository", () => {
  const workflow = readWorkflow();

  // The tag filter is a glob and a glob cannot express "digits then -myswy.N".
  // It narrows the trigger; the exact rule has to live in a step.
  const trigger = JSON.stringify(workflow.on?.push?.tags ?? []);
  assert.doesNotMatch(
    trigger,
    /"v\*\.\*\.\*"/,
    "a synced upstream tag must not start this workflow at all",
  );

  const verify = workflow.jobs?.verify;
  const meta = (verify?.steps ?? []).find((step) => step.id === "release_meta");
  assert.ok(meta, "verify must compute the release tag");
  assert.ok(
    meta.run.includes("^v[0-9]+\\.[0-9]+\\.[0-9]+-myswy\\.[0-9]+$"),
    "verify must match the distribution tag shape exactly",
  );
  assert.match(
    meta.run,
    /zzttzzmyswy\/multica/,
    "verify must refuse a repository outside the distribution",
  );
  assert.match(meta.run, /::error::/, "a rejected tag must fail the run, not warn");

  // The gate itself must stay: tests, race suite, vulnerability scan, no bypass.
  const verifyText = JSON.stringify(verify);
  assert.match(verifyText, /test-go\.sh --race/, "verify must run the race suite");
  assert.match(verifyText, /govulncheck/, "verify must run govulncheck");
  assert.doesNotMatch(
    JSON.stringify(workflow),
    /continue-on-error/,
    "no publishing job may soften a failing gate",
  );
});

test("a partial rerun of a merge job performs zero registry writes", async () => {
  const workflow = readWorkflow();
  const env = makeEnv({
    release_status: 200,
    repositories: {
      // Both tags are already published: this is the state after the first
      // attempt finished writing and then failed in the inspect step.
      [`zzttzzmyswy/${BACKEND}`]: { tags: [TAG], manifests: { [TAG]: { status: 200 } } },
      [`zzttzzmyswy/${WEB}`]: { tags: [TAG], manifests: { [TAG]: { status: 200 } } },
    },
  });
  const { child, port } = await startStub(env);
  try {
    stubDocker(env);
    const job = workflow.jobs?.["docker-backend-merge"];
    const vars = {
      "needs.verify.outputs.tag_name": TAG,
      "github.repository": "zzttzzmyswy/multica",
      "github.repository_owner": "zzttzzmyswy",
      "github.actor": "zzttzzmyswy",
      "github.workspace": root,
      "secrets.GITHUB_TOKEN": "test-token",
    };
    const writer = writerSteps(job, "imagetools create")[0];
    const stepVars = stepEnv(writer, vars);

    // Replay: the guard job's success is stored (not re-run), this job's steps
    // run from the top against a registry that already has the tag.
    assert.throws(
      () =>
        runStep(render(writer.run, vars), {
          env,
          cwd: env.dir,
          extraEnv: {
            ...stepVars,
            GITHUB_WORKSPACE: root,
            GITHUB_REPOSITORY: "zzttzzmyswy/multica",
            GITHUB_TOKEN: "test-token",
            GHCR_USERNAME: "zzttzzmyswy",
            GHCR_TOKEN: "test-token",
            GITHUB_API_URL: `http://127.0.0.1:${port}`,
            REGISTRY_API_BASE: `http://127.0.0.1:${port}`,
            REGISTRY_TOKEN_URL: `http://127.0.0.1:${port}/token`,
            DOCKER_METADATA_OUTPUT_JSON: JSON.stringify({ tags: [`ghcr.io/zzttzzmyswy/${BACKEND}:${TAG}`] }),
          },
        }),
      /already exists/,
      "the rerun must fail on the existing tag instead of pushing",
    );
    assert.equal(writeCount(env), 0, "the rerun must issue zero writes");
  } finally {
    child.kill();
    rmSync(env.dir, { recursive: true, force: true });
  }
});

test("a partial rerun of the web merge is not blocked by the backend's finished work", async () => {
  // The reported second-order defect: subtracting an initial "anything exists"
  // guard into every writer refuses a run whose sibling artifact went out fine.
  const workflow = readWorkflow();
  const env = makeEnv({
    release_status: 200,
    repositories: {
      // Backend and the release are done; web is the job being re-run and its
      // tag has not been written yet.
      [`zzttzzmyswy/${BACKEND}`]: { tags: [TAG], manifests: { [TAG]: { status: 200 } } },
      [`zzttzzmyswy/${WEB}`]: { tags: ["v0.9.0-myswy.0"], manifests: { "v0.9.0-myswy.0": { status: 200 } } },
    },
  });
  const { child, port } = await startStub(env);
  try {
    stubDocker(env);
    const vars = {
      "needs.verify.outputs.tag_name": TAG,
      "github.repository": "zzttzzmyswy/multica",
      "github.repository_owner": "zzttzzmyswy",
      "github.actor": "zzttzzmyswy",
      "github.workspace": root,
      "secrets.GITHUB_TOKEN": "test-token",
    };
    const writer = writerSteps(workflow.jobs?.["docker-web-merge"], "imagetools create")[0];
    const stepVars = stepEnv(writer, vars);
    runStep(render(writer.run, vars), {
      env,
      cwd: env.dir,
      extraEnv: {
        ...stepVars,
        GITHUB_WORKSPACE: root,
        GITHUB_REPOSITORY: "zzttzzmyswy/multica",
        GITHUB_TOKEN: "test-token",
        GHCR_USERNAME: "zzttzzmyswy",
        GHCR_TOKEN: "test-token",
        GITHUB_API_URL: `http://127.0.0.1:${port}`,
        REGISTRY_API_BASE: `http://127.0.0.1:${port}`,
        REGISTRY_TOKEN_URL: `http://127.0.0.1:${port}/token`,
        DOCKER_METADATA_OUTPUT_JSON: JSON.stringify({ tags: [`ghcr.io/zzttzzmyswy/${WEB}:${TAG}`] }),
      },
    });
    // Reaching the push is the assertion: a guard that reuses the pre-flight
    // rule would refuse here because the backend is already published. But
    // "reached the push" alone would also be true of a step with no guard at
    // all — the reported defect — so the guard's own registry request has to
    // appear, and it has to come first.
    const log = requests(env);
    const guardIndex = log.findIndex((line) => line.includes(`/v2/zzttzzmyswy/${WEB}/`));
    const writeIndex = log.findIndex((line) => line.startsWith("WRITE docker") && line.includes("imagetools create"));
    assert.ok(guardIndex >= 0, "the web merge must query the registry for its own tag before pushing");
    assert.ok(writeIndex >= 0, "the web merge must reach its push when only its own tag is free");
    assert.ok(guardIndex < writeIndex, "the web merge must check its tag before pushing it");
    assert.ok(
      !log.some((line) => line.includes(`${BACKEND}`)),
      "the web merge must not consult the backend's tag",
    );
  } finally {
    child.kill();
    rmSync(env.dir, { recursive: true, force: true });
  }
});

test("a partial rerun of the CLI job performs zero release writes", async () => {
  const workflow = readWorkflow();
  const env = makeEnv({
    // The release went out on the first attempt; the job failed later.
    release_status: 200,
    repositories: {},
  });
  const { child, port } = await startStub(env);
  try {
    stubGoreleaser(env);
    const vars = {
      "needs.verify.outputs.tag_name": TAG,
      "github.repository": "zzttzzmyswy/multica",
      "github.actor": "zzttzzmyswy",
      "github.workspace": root,
      "secrets.GITHUB_TOKEN": "test-token",
    };
    const cli = workflow.jobs?.cli;
    for (const step of runSteps(cli)) {
      if (!step.run.includes("myswy-release-guard.sh") && !step.run.includes("goreleaser")) continue;
      assert.throws(
        () =>
          runStep(render(step.run, vars), {
            env,
            cwd: root,
            extraEnv: {
              ...stepEnv(step, vars),
              GITHUB_TOKEN: "test-token",
              GITHUB_REPOSITORY: "zzttzzmyswy/multica",
              GITHUB_API_URL: `http://127.0.0.1:${port}`,
            },
          }),
        /already exists/,
        `${step.name} must fail rather than publish over the existing release`,
      );
      break; // the first failing step ends the job; later steps never run
    }
    assert.equal(writeCount(env), 0, "the rerun must not invoke GoReleaser at all");
    // Prove the stub could have counted it: the job must define the GoReleaser
    // step at all, or "zero writes" would be vacuous.
    assert.ok(
      (workflow.jobs?.cli?.steps ?? []).some((step) => String(step.uses ?? "").includes("goreleaser")),
      "the cli job must define the GoReleaser step the count is watching for",
    );
    assert.ok(
      (workflow.jobs?.cli?.steps ?? []).some((step) => String(step.run ?? "").includes("myswy-release-guard.sh")),
      "the cli job must define the guard step that is supposed to stop GoReleaser",
    );
  } finally {
    child.kill();
    rmSync(env.dir, { recursive: true, force: true });
  }
});

test("a first publish from an empty registry is allowed end to end", async () => {
  // The other half of the contract: the protection must not make a first
  // release impossible. This is the case the anonymous GHCR lookup broke.
  const workflow = readWorkflow();
  const env = makeEnv({ release_status: 404, repositories: {} });
  const { child, port } = await startStub(env);
  try {
    stubDocker(env);
    const vars = {
      "needs.verify.outputs.tag_name": TAG,
      "github.repository": "zzttzzmyswy/multica",
      "github.repository_owner": "zzttzzmyswy",
      "github.actor": "zzttzzmyswy",
      "github.workspace": root,
      "secrets.GITHUB_TOKEN": "test-token",
    };
    const writer = writerSteps(workflow.jobs?.["docker-backend-merge"], "imagetools create")[0];
    const stepVars = stepEnv(writer, vars);
    runStep(render(writer.run, vars), {
      env,
      cwd: env.dir,
      extraEnv: {
        ...stepVars,
        GITHUB_WORKSPACE: root,
        GITHUB_REPOSITORY: "zzttzzmyswy/multica",
        GITHUB_TOKEN: "test-token",
        GHCR_USERNAME: "zzttzzmyswy",
        GHCR_TOKEN: "test-token",
        GITHUB_API_URL: `http://127.0.0.1:${port}`,
        REGISTRY_API_BASE: `http://127.0.0.1:${port}`,
        REGISTRY_TOKEN_URL: `http://127.0.0.1:${port}/token`,
        DOCKER_METADATA_OUTPUT_JSON: JSON.stringify({ tags: [`ghcr.io/zzttzzmyswy/${BACKEND}:${TAG}`] }),
      },
    });
    assert.ok(
      requests(env).some((line) => line.includes("imagetools create")),
      "a first publish must reach the push",
    );
    // Every registry request carried credentials: an anonymous one would be
    // answered with a 403 for a package that does not exist yet.
    const registryRequests = requests(env).filter((line) => line.includes("/v2/") || line.includes("/token"));
    assert.ok(registryRequests.length > 0, "the guard must have queried the registry");
    for (const line of registryRequests) {
      assert.match(line, /auth=yes/, `every registry request must be authenticated: ${line}`);
    }
  } finally {
    child.kill();
    rmSync(env.dir, { recursive: true, force: true });
  }
});

test("the pre-flight guard refuses the whole release when any artifact exists", async () => {
  const workflow = readWorkflow();
  const env = makeEnv({
    release_status: 404,
    repositories: {
      [`zzttzzmyswy/${WEB}`]: { tags: [TAG], manifests: { [TAG]: { status: 200 } } },
    },
  });
  const { child, port } = await startStub(env);
  try {
    const vars = {
      "needs.verify.outputs.tag_name": TAG,
      "github.repository": "zzttzzmyswy/multica",
      "github.actor": "zzttzzmyswy",
      "github.workspace": root,
      "secrets.GITHUB_TOKEN": "test-token",
    };
    const guard = runSteps(workflow.jobs?.guard).find((step) => step.run.includes("myswy-release-guard.sh"));
    assert.ok(guard, "the guard job must run the guard");
    const guardVars = stepEnv(guard, vars);
    assert.throws(
      () =>
        runStep(render(guard.run, vars), {
          env,
          cwd: root,
          extraEnv: {
            ...guardVars,
            GITHUB_TOKEN: "test-token",
            GITHUB_REPOSITORY: "zzttzzmyswy/multica",
            GHCR_USERNAME: "zzttzzmyswy",
            GHCR_TOKEN: "test-token",
            GITHUB_API_URL: `http://127.0.0.1:${port}`,
            REGISTRY_API_BASE: `http://127.0.0.1:${port}`,
            REGISTRY_TOKEN_URL: `http://127.0.0.1:${port}/token`,
          },
        }),
      /already exists/,
      "one existing image tag must stop the whole release",
    );
  } finally {
    child.kill();
    rmSync(env.dir, { recursive: true, force: true });
  }
});
