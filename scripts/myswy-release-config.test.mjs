// Publishing-configuration invariants for the self-host distribution.
//
// These assert decisions a gate cannot see by running the workflow: which
// repository a release writes to, which assets it publishes, and whether the
// fork can accidentally publish into upstream's namespace. A wrong value here
// is not caught by a test suite — it shows up as a missing feature on a
// deployed instance, or as a fork build landing in the upstream Homebrew tap.
//
// They intentionally read the configuration files rather than a live GitHub
// state, so they run offline and cannot be satisfied by a passing CI run.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { parse } from "yaml";

const root = fileURLToPath(new URL("..", import.meta.url));

const read = (relPath) => readFileSync(new URL(relPath, import.meta.url), "utf8");
const readYaml = (relPath) => parse(read(relPath));

const UPSTREAM_OWNER = "multica-ai";
const DISTRIBUTION_OWNER = "zzttzzmyswy";

test("the CLI update source is pinned to the distribution repository", () => {
  const updateGo = read("../server/internal/cli/update.go");

  // ReleaseRepository is the single value every lookup derives from. If it
  // still named upstream, `multica update` would replace a distribution build
  // with one that lacks the attachment feature.
  const match = /const ReleaseRepository = "([^"]+)"/.exec(updateGo);
  assert.ok(match, "update.go must declare a ReleaseRepository constant");
  assert.equal(
    match[1],
    `${DISTRIBUTION_OWNER}/multica`,
    "ReleaseRepository must name the distribution repository",
  );

  // No release URL or API path may be hardcoded to another project.
  assert.doesNotMatch(
    updateGo,
    new RegExp(`repos/${UPSTREAM_OWNER}/`),
    "update.go must not hardcode an upstream release API path",
  );
  assert.doesNotMatch(
    updateGo,
    new RegExp(`github\\.com/${UPSTREAM_OWNER}/multica/releases`),
    "update.go must not hardcode an upstream release download URL",
  );

  // The brew route must fail closed rather than defaulting to upstream's tap.
  const brewDefault = /var BrewFormulaName = "([^"]*)"/.exec(updateGo);
  assert.ok(brewDefault, "update.go must declare BrewFormulaName");
  assert.equal(
    brewDefault[1],
    "",
    "BrewFormulaName must default to empty: a distribution build has no tap, and defaulting to upstream's would silently downgrade it",
  );
  assert.doesNotMatch(
    updateGo,
    new RegExp(`"brew", "upgrade", "${UPSTREAM_OWNER}/tap/multica"`),
    "update.go must not run brew upgrade against the upstream tap",
  );
});

test("the distribution GoReleaser config publishes no Homebrew formula", () => {
  const config = readYaml("../.goreleaser.myswy.yml");

  assert.equal(config.project_name, "multica", "archive names must stay multica-prefixed");

  // A `brews:` section with the upstream tap would make every fork tag push
  // fail (no token) or, worse, publish into the upstream tap.
  assert.equal(config.brews, undefined, ".goreleaser.myswy.yml must not declare a Homebrew formula");

  // Re-running a release must not swap already-published bytes.
  assert.equal(
    config.release?.replace_existing_artifacts,
    false,
    "a published version's artifacts must be immutable",
  );

  // Both archive names must be produced: the versioned one is what the updater
  // looks for, the legacy one is what older installed CLIs look for.
  const names = (config.archives ?? []).map((archive) => archive.name_template);
  assert.ok(
    names.includes("{{ .ProjectName }}-cli-{{ .Version }}-{{ .Os }}-{{ .Arch }}"),
    "must publish the versioned archive name the updater resolves",
  );
  assert.ok(
    names.includes("{{ .ProjectName }}_{{ .Os }}_{{ .Arch }}"),
    "must keep publishing the legacy archive name older CLIs self-update from",
  );
  assert.equal(config.checksum?.name_template, "checksums.txt", "the updater expects this manifest name");

  // ldflags are what make `multica version` report the tag and commit, which
  // is how an operator confirms a deployment or update landed.
  const ldflags = config.builds?.[0]?.ldflags ?? [];
  for (const flag of ["-X main.version={{.Version}}", "-X main.buildCommit={{.FullCommit}}"]) {
    assert.ok(ldflags.includes(flag), `builds[0].ldflags must include ${flag}`);
  }
});

test("the distribution release workflow publishes only fork namespaces", () => {
  const workflow = readYaml("../.github/workflows/release-myswy.yml");
  const text = read("../.github/workflows/release-myswy.yml");

  // The image names resolve through the owner, so assert on the literal paths
  // the workflow builds and on the absence of any upstream reference.
  assert.doesNotMatch(
    text,
    new RegExp(`ghcr\\.io/${UPSTREAM_OWNER}/`),
    "the distribution workflow must not reference upstream's GHCR namespace",
  );
  assert.match(
    text,
    /ghcr\.io\/\$\{\{ github\.repository_owner \}\}\/multica-backend/,
    "backend image must resolve under the running repository's owner",
  );
  assert.match(
    text,
    /ghcr\.io\/\$\{\{ github\.repository_owner \}\}\/multica-web/,
    "web image must resolve under the running repository's owner",
  );

  // No floating `latest`: a deployment pins an exact version, and a floating
  // tag is the one way to get a different binary than the one verified.
  for (const [jobName, job] of Object.entries(workflow.jobs ?? {})) {
    const tags = JSON.stringify(job);
    assert.doesNotMatch(
      tags,
      /value=latest/,
      `${jobName} must not publish a floating latest tag`,
    );
  }

  // Publishing must be gated on the same tests and vulnerability scan as
  // upstream's release, with no bypass variable.
  const verifySteps = JSON.stringify(workflow.jobs?.verify ?? {});
  assert.match(verifySteps, /test-go\.sh --race/, "verify must run the race suite");
  assert.match(verifySteps, /govulncheck/, "verify must run govulncheck");
  assert.doesNotMatch(
    JSON.stringify(workflow),
    /ALLOW_VULN_BYPASS_FOR_TAG/,
    "the distribution release must not carry a vulnerability-scan bypass",
  );

  // Nothing may build Desktop/mobile installers or a Helm chart: this
  // distribution does not publish them.
  assert.doesNotMatch(text, /electron-builder|package\.mjs/, "must not package Desktop installers");
  assert.doesNotMatch(text, /helm push|azure\/setup-helm/, "must not publish a Helm chart");

  // GoReleaser must use the fork's config, which has no tap.
  assert.match(
    text,
    /--config \.goreleaser\.myswy\.yml/,
    "GoReleaser must run with the fork's config, whose absence of a brew section is what keeps upstream's tap untouched",
  );
});

test("upstream's release workflow cannot publish from this fork", () => {
  // fork/main is zzttzzmyswy/multica, but release.yml triggers on any v*.*.*
  // tag. Every job that writes an artifact must therefore be owner-guarded, or
  // a fork tag would publish into the fork's GHCR namespace from two
  // workflows at once — one of them publishing a mutable `latest`.
  const workflow = readYaml("../.github/workflows/release.yml");

  const publishingJobs = [
    "verify",
    "release",
    "docker-backend-build",
    "docker-backend-merge",
    "docker-web-build",
    "docker-web-merge",
    "helm-chart",
  ];
  for (const jobName of publishingJobs) {
    const job = workflow.jobs?.[jobName];
    assert.ok(job, `release.yml must still define ${jobName}`);
    assert.match(
      String(job.if ?? ""),
      /github\.repository_owner == 'multica-ai'/,
      `${jobName} must be guarded to the upstream owner so a fork tag cannot publish through it`,
    );
  }
});

test("self-host image defaults point at the distribution namespace", () => {
  const compose = read("../docker-compose.selfhost.yml");
  const envExample = read("../.env.example");
  const helmValues = readYaml("../deploy/helm/multica/values.yaml");

  assert.doesNotMatch(
    compose,
    new RegExp(`ghcr\\.io/${UPSTREAM_OWNER}/multica-`),
    "docker-compose.selfhost.yml must not default to upstream images",
  );
  assert.doesNotMatch(
    envExample,
    new RegExp(`ghcr\\.io/${UPSTREAM_OWNER}/multica-`),
    ".env.example must not default to upstream images",
  );
  assert.equal(
    helmValues.images?.backend?.repository,
    `ghcr.io/${DISTRIBUTION_OWNER}/multica-backend`,
    "helm backend image must default to the distribution namespace",
  );
  assert.equal(
    helmValues.images?.frontend?.repository,
    `ghcr.io/${DISTRIBUTION_OWNER}/multica-web`,
    "helm frontend image must default to the distribution namespace",
  );

  // The default tag must name a real distribution build, not a floating one.
  const imageTag = /^MULTICA_IMAGE_TAG=(.+)$/m.exec(envExample);
  assert.ok(imageTag, ".env.example must set MULTICA_IMAGE_TAG");
  assert.match(
    imageTag[1].trim(),
    /^v\d+\.\d+\.\d+-myswy\.\d+$/,
    ".env.example must pin a distribution version, not `latest`",
  );
  assert.doesNotMatch(
    compose,
    /MULTICA_IMAGE_TAG:-latest/,
    "compose must not fall back to a floating latest tag",
  );
});

test("the distribution installer only ever targets its own repository", () => {
  const installer = read("../scripts/install-myswy.sh");

  assert.match(
    installer,
    new RegExp(`REPO_OWNER="${DISTRIBUTION_OWNER}"`),
    "the installer must name the distribution owner",
  );
  assert.match(installer, /REPO_NAME="multica"/, "the installer must name the repository");
  // No executable line may name the upstream project. Comments legitimately
  // explain why this installer exists instead of scripts/install.sh, so only
  // non-comment lines are checked.
  const codeLines = installer
    .split("\n")
    .filter((line) => !line.trimStart().startsWith("#"));
  const upstreamRefs = codeLines.filter((line) => line.includes(UPSTREAM_OWNER));
  assert.deepEqual(
    upstreamRefs,
    [],
    `the installer must not reference the upstream project outside comments: ${upstreamRefs.join(" | ")}`,
  );
  // Only distribution tags may be installed: the fork also carries upstream's
  // tags, and installing one of those would replace the distribution build.
  assert.match(
    installer,
    /DISTRIBUTION_SUFFIX="-myswy\."/,
    "the installer must filter to distribution-suffixed tags",
  );
  // Verification is not optional.
  assert.match(installer, /verify_checksum/, "the installer must verify archive checksums");
  assert.match(installer, /checksums\.txt/, "the installer must download the checksum manifest");
});
