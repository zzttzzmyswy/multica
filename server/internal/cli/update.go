package cli

import (
	"archive/tar"
	"archive/zip"
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/multica-ai/multica/server/internal/selfexec"
)

// ChecksumManifestName is the asset name GoReleaser publishes for the
// checksum manifest (`checksum.name_template: "checksums.txt"` in
// .goreleaser.yml). Kept as a constant rather than inlined so a future rename
// changes one place.
const ChecksumManifestName = "checksums.txt"

// ReleaseRepository is the single source of truth for where this build's
// release metadata, archives, and checksum manifests live. Every request path
// in this file derives from it — latest, by-tag, archive, and checksums.txt —
// so a distribution cannot read release metadata from one repository and
// download archives from another.
//
// It is a constant rather than a variable on purpose. This repository is a
// maintained fork whose builds carry features the upstream releases lack, so
// there is no configuration under which pointing an installed binary at
// upstream is correct: that would silently replace the operator's build with
// one that has different behavior. Operators who need a mirror set
// MULTICA_RELEASE_API_BASE_URL / MULTICA_RELEASE_DOWNLOAD_BASE_URL, which
// change the host but keep this repository in the path.
const ReleaseRepository = "zzttzzmyswy/multica"

// defaultReleaseAPIBaseURL is the GitHub Releases API root. A mirror only
// rewrites the host; the /repos/<ReleaseRepository>/releases/... path is
// preserved.
const defaultReleaseAPIBaseURL = "https://api.github.com"

// MULTICA_RELEASE_API_BASE_URL points at a GitHub Releases API-compatible
// mirror. MULTICA_RELEASE_DOWNLOAD_BASE_URL points at an artifact mirror
// serving /<tag>/<asset-name>; when unset, the release-provided URLs win.
// Both are host overrides only: the repository in the request path stays
// ReleaseRepository.
const releaseAPIBaseURLEnv = "MULTICA_RELEASE_API_BASE_URL"
const releaseDownloadBaseURLEnv = "MULTICA_RELEASE_DOWNLOAD_BASE_URL"

const DefaultUpdateDownloadTimeout = 120 * time.Second

func releaseAPIBaseURL() string {
	if value := strings.TrimRight(strings.TrimSpace(os.Getenv(releaseAPIBaseURLEnv)), "/"); value != "" {
		return value
	}
	return defaultReleaseAPIBaseURL
}

// releaseRepository is the "owner/name" used for every latest/tag lookup.
func releaseRepository() string {
	return ReleaseRepository
}

// ReleaseWebURL is the human-facing page an operator should visit for this
// build's releases. Diagnostics and install instructions print it instead of
// hardcoding a URL, so they cannot point somewhere the binary does not update
// from.
func ReleaseWebURL() string {
	return "https://github.com/" + ReleaseRepository
}

// ReleaseArchiveURL is the download URL for one asset of one release tag.
func ReleaseArchiveURL(targetVersion, assetName string) string {
	return fmt.Sprintf("%s/releases/download/%s/%s",
		ReleaseWebURL(), url.PathEscape(normalizeReleaseTag(targetVersion)), url.PathEscape(assetName))
}

// releaseAPIPath builds the /repos/<repo>/releases/... path shared by the
// latest and by-tag lookups, so the two can never disagree about the source.
func releaseAPIPath(suffix string) string {
	return "/repos/" + releaseRepository() + "/releases/" + suffix
}

func releaseDownloadBaseURL() string {
	return strings.TrimRight(strings.TrimSpace(os.Getenv(releaseDownloadBaseURLEnv)), "/")
}

func releaseAssetDownloadURL(assetName, targetVersion, fallback string) string {
	base := releaseDownloadBaseURL()
	if base == "" {
		return fallback
	}
	return fmt.Sprintf("%s/%s/%s", base, url.PathEscape(normalizeReleaseTag(targetVersion)), url.PathEscape(assetName))
}

// ErrNoBrewFormula reports that this build has no Homebrew formula to upgrade
// through. The caller must surface it as an explicit failure rather than
// silently falling back to a different formula.
var ErrNoBrewFormula = errors.New("this build publishes no Homebrew formula")

// BrewInstallBlockedError explains why a Homebrew-installed copy of this build
// cannot be updated in place, and what to run instead. Both the CLI's `update`
// command and the daemon's update path return it, so the two cannot give an
// operator different instructions for the same situation.
//
// Replacing a keg's binary in place is not an option: brew owns that path, and
// the next `brew upgrade` or `brew doctor` would either overwrite the
// replacement or report a corrupted keg.
func BrewInstallBlockedError(targetVersion, goos, goarch string) error {
	return fmt.Errorf("this build is installed via Homebrew, but %s publishes no Homebrew formula;\n"+
		"reinstall from this build's release archives instead:\n  %s",
		ReleaseRepository,
		ReleaseArchiveURL(targetVersion, ReleaseAssetName(targetVersion, goos, goarch)))
}

// GitHubRelease is the subset of the GitHub releases API response we need.
type GitHubRelease struct {
	TagName    string               `json:"tag_name"`
	HTMLURL    string               `json:"html_url"`
	Assets     []GitHubReleaseAsset `json:"assets"`
	Prerelease bool                 `json:"prerelease"`
	Draft      bool                 `json:"draft"`
	// PublishedAt orders releases for newest-build selection. GitHub returns
	// the list newest-first, but sorting on this field keeps the choice
	// independent of that guarantee.
	PublishedAt string `json:"published_at"`
}

// IsReleaseVersion reports whether v looks like a tagged release version
// (e.g. "0.1.13", "v0.1.13") rather than a dev build (e.g. an empty version
// or a `git describe`–style "v0.2.15-235-gdaf0e935"). The auto-update poller
// uses this to skip self-update for source builds, where downgrading to a
// public release would clobber unreleased changes.
func IsReleaseVersion(v string) bool {
	s := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(v), "v"))
	if s == "" {
		return false
	}
	parts := strings.Split(s, ".")
	if len(parts) != 3 {
		return false
	}
	for _, p := range parts {
		if p == "" {
			return false
		}
		for _, r := range p {
			if r < '0' || r > '9' {
				return false
			}
		}
	}
	return true
}

// IsNewerVersion reports whether latest is strictly newer than current. Both
// arguments may carry an optional "v" prefix; non-numeric tails are ignored
// (a 4th component, pre-release tag, etc.). Returns false if either side
// cannot be parsed — the caller treats that as "stay on current".
func IsNewerVersion(latest, current string) bool {
	l, ok := parseReleaseVersion(latest)
	if !ok {
		return false
	}
	c, ok := parseReleaseVersion(current)
	if !ok {
		return false
	}
	for i := 0; i < 3; i++ {
		if l[i] != c[i] {
			return l[i] > c[i]
		}
	}
	return false
}

// parseReleaseVersion extracts the three numeric components of v. Returns
// (parts, true) on success; (_, false) when v is missing, malformed, or
// carries any non-numeric tail (a dev-describe suffix, a 4th component, a
// pre-release tag, etc.). The strict shape is intentional: this is the only
// parser used by IsNewerVersion, and the autoUpdateLoop must never silently
// downgrade a developer build to a public release just because the
// dev-describe patch happened to look numeric after trimming.
func parseReleaseVersion(v string) ([3]int, bool) {
	s := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(v), "v"))
	if s == "" {
		return [3]int{}, false
	}
	parts := strings.Split(s, ".")
	if len(parts) != 3 {
		return [3]int{}, false
	}
	var out [3]int
	for i, p := range parts {
		if p == "" {
			return [3]int{}, false
		}
		for _, r := range p {
			if r < '0' || r > '9' {
				return [3]int{}, false
			}
		}
		n, err := strconv.Atoi(p)
		if err != nil {
			return [3]int{}, false
		}
		out[i] = n
	}
	return out, true
}

type GitHubReleaseAsset struct {
	Name               string `json:"name"`
	BrowserDownloadURL string `json:"browser_download_url"`
}

func releaseArchiveExtension(goos string) string {
	if goos == "windows" {
		return "zip"
	}
	return "tar.gz"
}

func normalizeReleaseTag(targetVersion string) string {
	tag := strings.TrimSpace(targetVersion)
	if !strings.HasPrefix(tag, "v") {
		tag = "v" + tag
	}
	return tag
}

// releaseAssetCandidates lists the archive names a release may publish for one
// platform, most-preferred first.
func releaseAssetCandidates(targetVersion, goos, goarch string) []string {
	tag := normalizeReleaseTag(targetVersion)
	version := strings.TrimPrefix(tag, "v")
	ext := releaseArchiveExtension(goos)
	// Prefer the versioned name (current scheme); fall back to the legacy
	// `multica_{os}_{arch}` name for releases that still ship it.
	return []string{
		ReleaseAssetName(version, goos, goarch),
		fmt.Sprintf("multica_%s_%s.%s", goos, goarch, ext),
	}
}

// ReleaseAssetName is the versioned archive name for one platform, matching
// .goreleaser.yml's `versioned` archive template. Exported so install
// instructions and error messages print the exact asset the updater looks for
// instead of a hand-written approximation that drifts.
func ReleaseAssetName(version, goos, goarch string) string {
	return fmt.Sprintf("multica-cli-%s-%s-%s.%s",
		strings.TrimPrefix(normalizeReleaseTag(version), "v"), goos, goarch, releaseArchiveExtension(goos))
}

func findReleaseAsset(assets []GitHubReleaseAsset, targetVersion, goos, goarch string) (*GitHubReleaseAsset, error) {
	for _, candidate := range releaseAssetCandidates(targetVersion, goos, goarch) {
		for i := range assets {
			if assets[i].Name == candidate {
				return &assets[i], nil
			}
		}
	}

	candidates := strings.Join(releaseAssetCandidates(targetVersion, goos, goarch), ", ")
	return nil, fmt.Errorf("no matching release asset for %s/%s (tried: %s)", goos, goarch, candidates)
}

// findChecksumManifestAsset locates the GoReleaser-generated checksums.txt
// among a release's assets. Required for the direct-download path's SHA-256
// verification — if it is missing we refuse to replace the binary rather
// than fall back to unverified install, because the auto-update poller runs
// unattended and an unverified binary swap is a supply-chain risk.
func findChecksumManifestAsset(assets []GitHubReleaseAsset) (*GitHubReleaseAsset, error) {
	for i := range assets {
		if assets[i].Name == ChecksumManifestName {
			return &assets[i], nil
		}
	}
	return nil, fmt.Errorf("checksum manifest %q not present in release", ChecksumManifestName)
}

// parseChecksumManifest reads a GoReleaser-style "<sha256>  <filename>"
// manifest and returns the lowercase hex SHA-256 for assetName. Returns an
// error if the asset is absent so a typo (or the wrong manifest from a
// different release) fails closed rather than silently disabling
// verification.
func parseChecksumManifest(manifest []byte, assetName string) (string, error) {
	scanner := bufio.NewScanner(bytes.NewReader(manifest))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		// GoReleaser's default separator is two spaces; some tools use one
		// or pad with tabs. strings.Fields handles all of those at once.
		if len(fields) < 2 {
			continue
		}
		if fields[1] == assetName {
			return strings.ToLower(fields[0]), nil
		}
	}
	if err := scanner.Err(); err != nil {
		return "", fmt.Errorf("read checksum manifest: %w", err)
	}
	return "", fmt.Errorf("checksum for %q not found in manifest", assetName)
}

// verifyAssetSHA256 returns nil when the SHA-256 of data matches the lowercase
// hex expected value, or an error otherwise. The error includes both digests
// so a corrupted asset is diagnosable from the log without re-downloading.
func verifyAssetSHA256(data []byte, expectedHex, assetName string) error {
	if expectedHex == "" {
		return fmt.Errorf("empty expected checksum for %q", assetName)
	}
	sum := sha256.Sum256(data)
	actual := hex.EncodeToString(sum[:])
	if !strings.EqualFold(actual, expectedHex) {
		return fmt.Errorf("checksum mismatch for %q: expected %s, got %s", assetName, expectedHex, actual)
	}
	return nil
}

// FetchReleaseByTag fetches one release's metadata from ReleaseRepository.
// Unlike FetchLatestRelease it can name a specific tag, which is what a pinned
// update and a rolled-back install both need: `latest` is a moving target, and
// pinning is the only way to install a version that is not the newest one.
func FetchReleaseByTag(tag string) (*GitHubRelease, error) {
	return fetchReleaseByTag(normalizeReleaseTag(tag))
}

func fetchReleaseByTag(tag string) (*GitHubRelease, error) {
	client := &http.Client{Timeout: 10 * time.Second}
	req, err := http.NewRequest(http.MethodGet, releaseAPIBaseURL()+releaseAPIPath("tags/"+url.PathEscape(tag)), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("release API returned %d", resp.StatusCode)
	}

	var release GitHubRelease
	if err := json.NewDecoder(resp.Body).Decode(&release); err != nil {
		return nil, err
	}
	return &release, nil
}

// FetchLatestRelease fetches the newest release of ReleaseRepository that this
// build can actually install.
//
// It does NOT use the `/releases/latest` endpoint. Every distribution release is
// a prerelease, and GitHub excludes prereleases from that endpoint — it would
// return 404 no matter how many builds were published, which is exactly the
// failure an operator would hit running `multica update` with no arguments.
//
// So the list endpoint is used and the newest distribution tag that carries an
// archive for this platform is selected. Upstream releases that happen to share
// the repository (a synced `v0.9.0`) are never selected: their tags lack the
// distribution suffix, and installing one would replace this build with a
// binary that has different behavior.
func FetchLatestRelease() (*GitHubRelease, error) {
	releases, err := listReleases()
	if err != nil {
		return nil, err
	}

	var newest *GitHubRelease
	var newestVersion [4]int
	for i := range releases {
		release := &releases[i]
		if release.Draft {
			continue
		}
		if !IsDistributionTag(release.TagName) {
			continue
		}
		if !hasReleaseAssetFor(release.Assets, release.TagName, runtime.GOOS, runtime.GOARCH) {
			continue
		}
		version, ok := parseDistributionVersion(release.TagName)
		if !ok {
			continue
		}
		if newest == nil || versionGreater(version, newestVersion) {
			newest, newestVersion = release, version
		}
	}
	if newest == nil {
		return nil, fmt.Errorf("no published distribution build for %s/%s in %s",
			runtime.GOOS, runtime.GOARCH, ReleaseRepository)
	}
	return newest, nil
}

// listReleases fetches one page of releases. The list endpoint includes
// prereleases, which is the whole reason it is used instead of `latest`.
func listReleases() ([]GitHubRelease, error) {
	client := &http.Client{Timeout: 10 * time.Second}
	// per_page=100 is GitHub's maximum; the newest distribution build is always
	// in the first page because releases are returned newest-first.
	req, err := http.NewRequest(http.MethodGet, releaseAPIBaseURL()+releaseAPIPath("?per_page=100"), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("release API returned %d", resp.StatusCode)
	}

	var releases []GitHubRelease
	if err := json.NewDecoder(resp.Body).Decode(&releases); err != nil {
		return nil, fmt.Errorf("decode release list: %w", err)
	}
	return releases, nil
}

// DistributionTagSuffix marks a release as this distribution's build.
const DistributionTagSuffix = "-myswy."

// IsDistributionTag reports whether tag is one of this distribution's releases
// (vX.Y.Z-myswy.N) rather than an upstream tag synced into the same repository.
func IsDistributionTag(tag string) bool {
	return strings.Contains(tag, DistributionTagSuffix)
}

// parseDistributionVersion splits vX.Y.Z-myswy.N into its four numeric
// components. A tag of any other shape returns false.
func parseDistributionVersion(tag string) ([4]int, bool) {
	trimmed := strings.TrimPrefix(strings.TrimSpace(tag), "v")
	base, tail, found := strings.Cut(trimmed, DistributionTagSuffix)
	if !found {
		return [4]int{}, false
	}

	core, ok := parseReleaseVersion(base)
	if !ok {
		return [4]int{}, false
	}

	// The build number is the leading digits of the tail; a trailing suffix
	// ("1-rc1") is not something this distribution publishes, so it is refused
	// rather than silently compared as 1.
	digits := tail
	if i := strings.IndexFunc(tail, func(r rune) bool { return r < '0' || r > '9' }); i >= 0 {
		digits = tail[:i]
	}
	if digits == "" {
		return [4]int{}, false
	}
	build, err := strconv.Atoi(digits)
	if err != nil {
		return [4]int{}, false
	}
	return [4]int{core[0], core[1], core[2], build}, true
}

func versionGreater(a, b [4]int) bool {
	for i := range a {
		if a[i] != b[i] {
			return a[i] > b[i]
		}
	}
	return false
}

// hasReleaseAssetFor reports whether a release publishes an archive this
// platform can install. A release that only built other platforms must be
// skipped, not selected and then failed at download time.
func hasReleaseAssetFor(assets []GitHubReleaseAsset, targetVersion, goos, goarch string) bool {
	_, err := findReleaseAsset(assets, targetVersion, goos, goarch)
	return err == nil
}

// knownBrewPrefixes lists the install roots Homebrew uses on each platform.
// Order is irrelevant — the prefixes do not nest.
var knownBrewPrefixes = []string{"/opt/homebrew", "/usr/local", "/home/linuxbrew/.linuxbrew"}

// MatchKnownBrewPrefix returns the Homebrew prefix whose Cellar contains path,
// or "" if path is not under a known Cellar. It is the offline equivalent of
// `brew --prefix`: callers reach for it when `brew --prefix` is unavailable
// (brew not on PATH) but the binary's path still betrays its install root.
func MatchKnownBrewPrefix(path string) string {
	for _, prefix := range knownBrewPrefixes {
		if strings.HasPrefix(path, prefix+"/Cellar/") {
			return prefix
		}
	}
	return ""
}

// IsBrewInstall checks whether the running multica binary was installed via Homebrew.
// The check itself lives in brewInstallForPath (stable_exe.go) so it stays
// one implementation with the stable-path resolver that depends on it.
func IsBrewInstall() bool {
	exePath, err := selfexec.Resolve()
	if err != nil {
		return false
	}
	return brewInstallForPath(exePath)
}

// GetBrewPrefix returns the Homebrew prefix by running `brew --prefix`, or empty string.
// Bounded: a wedged brew (broken shellenv, unreachable network home) must not
// park the caller — the daemon's reload loop reaches here periodically.
func GetBrewPrefix() string {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "brew", "--prefix")
	cmd.WaitDelay = 2 * time.Second
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// BrewFormulaName is the Homebrew formula this build upgrades through. It is a
// build-time property for the same reason ReleaseRepository is: a distribution
// build must never run `brew upgrade multica-ai/tap/multica`, because that
// replaces it with an upstream binary that lacks its features.
//
// This distribution publishes no tap, so the default is empty and the brew
// route fails closed. Defaulting to the upstream formula would make every
// mistyped build silently downgrade to upstream, which is exactly the failure
// the fork exists to prevent. A build that does ship a tap sets this at link
// time via `-X .../cli.BrewFormulaName=owner/tap/name`.
var BrewFormulaName = ""

// UpdateViaBrew runs `brew upgrade <BrewFormulaName>`.
// Returns the combined output and any error.
func UpdateViaBrew() (string, error) {
	if BrewFormulaName == "" {
		// Fail loudly rather than picking some other formula. An install with
		// no tap of its own must update through the release archives, and the
		// caller turns this into a message telling the operator how.
		return "", ErrNoBrewFormula
	}
	cmd := exec.Command("brew", "upgrade", BrewFormulaName)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("brew upgrade failed: %w", err)
	}
	return string(out), nil
}

func updateDownloadTimeoutOrDefault(timeout time.Duration) time.Duration {
	if timeout <= 0 {
		return DefaultUpdateDownloadTimeout
	}
	return timeout
}

// fetchURLBytes does a GET with the given timeout and returns the response
// body in full. Used for the checksum manifest (tiny) and the release
// archive (single-digit MB). The checksum verification path requires buffered
// bytes so streaming would just push the buffer into the caller anyway.
func fetchURLBytes(url string, timeout time.Duration) ([]byte, error) {
	client := &http.Client{Timeout: updateDownloadTimeoutOrDefault(timeout)}
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d from %s", resp.StatusCode, url)
	}
	return io.ReadAll(resp.Body)
}

// UpdateViaDownload downloads the latest release binary from GitHub and replaces
// the current executable in-place. Returns the combined output message and any error.
func UpdateViaDownload(targetVersion string) (string, error) {
	return UpdateViaDownloadWithTimeout(targetVersion, DefaultUpdateDownloadTimeout)
}

// UpdateViaDownloadWithTimeout downloads the latest release binary with a caller-selected timeout.
func UpdateViaDownloadWithTimeout(targetVersion string, downloadTimeout time.Duration) (string, error) {
	// Determine current binary path.
	exePath, err := selfexec.Resolve()
	if err != nil {
		return "", fmt.Errorf("resolve executable path: %w", err)
	}
	exePath, err = filepath.EvalSymlinks(exePath)
	if err != nil {
		return "", fmt.Errorf("resolve symlink: %w", err)
	}

	tag := normalizeReleaseTag(targetVersion)
	release, err := fetchReleaseByTag(tag)
	if err != nil {
		return "", fmt.Errorf("fetch release metadata: %w", err)
	}
	asset, err := findReleaseAsset(release.Assets, tag, runtime.GOOS, runtime.GOARCH)
	if err != nil {
		return "", err
	}
	manifestAsset, err := findChecksumManifestAsset(release.Assets)
	if err != nil {
		return "", err
	}
	downloadURL := releaseAssetDownloadURL(asset.Name, tag, asset.BrowserDownloadURL)
	assetName := asset.Name

	// Pull the checksum manifest first so a release that is half-published
	// (archives uploaded but checksums.txt not yet) fails before we eat the
	// archive's bandwidth.
	timeout := updateDownloadTimeoutOrDefault(downloadTimeout)
	manifestURL := releaseAssetDownloadURL(manifestAsset.Name, tag, manifestAsset.BrowserDownloadURL)
	manifestData, err := fetchURLBytes(manifestURL, timeout)
	if err != nil {
		return "", fmt.Errorf("download checksum manifest: %w", err)
	}
	expectedSum, err := parseChecksumManifest(manifestData, assetName)
	if err != nil {
		return "", fmt.Errorf("parse checksum manifest: %w", err)
	}

	// Buffer the archive into memory so we can verify the full SHA-256
	// before writing anything to disk. Release archives are ~10–30 MB; the
	// extraction code already buffers zip archives in full (random access
	// requirement), so this is not a new memory cost on Windows. For tar.gz
	// it adds a single in-RAM copy, which is preferable to running the
	// untrusted bytes through gzip+tar extraction before the SHA-256 check.
	archiveData, err := fetchURLBytes(downloadURL, timeout)
	if err != nil {
		return "", fmt.Errorf("download failed: %w", err)
	}

	if err := verifyAssetSHA256(archiveData, expectedSum, assetName); err != nil {
		// Do NOT extract or replace; the next poll tick will retry. A
		// corrupted asset is rare enough that retrying through the same
		// CDN is the right default; persistent failures will surface in
		// the daemon log.
		return "", fmt.Errorf("verify download: %w", err)
	}

	// Extract the binary from the archive.
	binaryName := "multica"
	if runtime.GOOS == "windows" {
		binaryName = "multica.exe"
	}
	var binaryData []byte
	if runtime.GOOS == "windows" {
		binaryData, err = extractBinaryFromZip(bytes.NewReader(archiveData), binaryName)
	} else {
		binaryData, err = extractBinaryFromTarGz(bytes.NewReader(archiveData), binaryName)
	}
	if err != nil {
		return "", fmt.Errorf("extract binary: %w", err)
	}

	// Atomic replace: write to temp file, then rename over the original.
	dir := filepath.Dir(exePath)
	tmpFile, err := os.CreateTemp(dir, "multica-update-*")
	if err != nil {
		return "", fmt.Errorf("create temp file: %w", err)
	}
	tmpPath := tmpFile.Name()

	if _, err := tmpFile.Write(binaryData); err != nil {
		tmpFile.Close()
		os.Remove(tmpPath)
		return "", fmt.Errorf("write temp file: %w", err)
	}
	tmpFile.Close()

	// Preserve original file permissions.
	info, err := os.Stat(exePath)
	if err != nil {
		os.Remove(tmpPath)
		return "", fmt.Errorf("stat original binary: %w", err)
	}
	if err := os.Chmod(tmpPath, info.Mode()); err != nil {
		os.Remove(tmpPath)
		return "", fmt.Errorf("chmod temp file: %w", err)
	}

	// Replace the original binary. On Windows this moves the running executable
	// aside first; on Unix a plain rename over the running inode is fine.
	if err := replaceBinary(tmpPath, exePath); err != nil {
		os.Remove(tmpPath)
		return "", fmt.Errorf("replace binary: %w", err)
	}

	return fmt.Sprintf("Downloaded %s and replaced %s", assetName, exePath), nil
}

// extractBinaryFromTarGz reads a .tar.gz stream and returns the contents of the
// named file entry.
func extractBinaryFromTarGz(r io.Reader, name string) ([]byte, error) {
	gz, err := gzip.NewReader(r)
	if err != nil {
		return nil, fmt.Errorf("gzip reader: %w", err)
	}
	defer gz.Close()

	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			return nil, fmt.Errorf("binary %q not found in archive", name)
		}
		if err != nil {
			return nil, fmt.Errorf("read tar: %w", err)
		}
		// Match the binary name (may be prefixed with a directory).
		if filepath.Base(hdr.Name) == name && hdr.Typeflag == tar.TypeReg {
			data, err := io.ReadAll(tr)
			if err != nil {
				return nil, fmt.Errorf("read binary: %w", err)
			}
			return data, nil
		}
	}
}

// extractBinaryFromZip reads a .zip stream and returns the contents of the
// named file entry. The zip format requires random access, so the full archive
// is buffered in memory.
func extractBinaryFromZip(r io.Reader, name string) ([]byte, error) {
	buf, err := io.ReadAll(r)
	if err != nil {
		return nil, fmt.Errorf("read zip data: %w", err)
	}

	zr, err := zip.NewReader(bytes.NewReader(buf), int64(len(buf)))
	if err != nil {
		return nil, fmt.Errorf("zip reader: %w", err)
	}

	for _, f := range zr.File {
		if filepath.Base(f.Name) == name && !f.FileInfo().IsDir() {
			rc, err := f.Open()
			if err != nil {
				return nil, fmt.Errorf("open zip entry: %w", err)
			}
			defer rc.Close()

			data, err := io.ReadAll(rc)
			if err != nil {
				return nil, fmt.Errorf("read binary: %w", err)
			}
			return data, nil
		}
	}
	return nil, fmt.Errorf("binary %q not found in archive", name)
}
