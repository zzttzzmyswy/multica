package cli

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// releaseRecorder is a fake GitHub Releases API that records every path it was
// asked for, so a test can assert not just the answer but that no request went
// anywhere else.
type releaseRecorder struct {
	mu        sync.Mutex
	paths     []string
	latestTag string
	tags      map[string]string // normalized tag -> tag name to echo back
	assets    []GitHubReleaseAsset
	// releases backs the list endpoint, which is what newest-build selection
	// reads.
	releases []GitHubRelease
}

func (r *releaseRecorder) record(path string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.paths = append(r.paths, path)
}

func (r *releaseRecorder) recorded() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.paths...)
}

func (r *releaseRecorder) server(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		r.record(req.URL.Path)

		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasSuffix(req.URL.Path, "/releases/latest"):
			// GitHub excludes prereleases here. Serving one would recreate the
			// fixture that hid the reported defect.
			if r.latestTag == "" {
				http.NotFound(w, req)
				return
			}
			_ = json.NewEncoder(w).Encode(GitHubRelease{TagName: r.latestTag, Assets: r.assets})
		case strings.Contains(req.URL.Path, "/releases/tags/"):
			tag := req.URL.Path[strings.LastIndex(req.URL.Path, "/")+1:]
			name, ok := r.tags[tag]
			if !ok {
				http.NotFound(w, req)
				return
			}
			_ = json.NewEncoder(w).Encode(GitHubRelease{TagName: name, Assets: r.assets})
		case strings.Contains(req.URL.Path, "/releases"):
			_ = json.NewEncoder(w).Encode(r.releases)
		default:
			http.NotFound(w, req)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestReleaseSourceDefaultsToGitHub(t *testing.T) {
	t.Setenv(releaseAPIBaseURLEnv, "")
	t.Setenv(releaseDownloadBaseURLEnv, "")

	if got := releaseAPIBaseURL(); got != defaultReleaseAPIBaseURL {
		t.Fatalf("release API base URL = %q, want %q", got, defaultReleaseAPIBaseURL)
	}
	if got := releaseAssetDownloadURL("archive.tar.gz", "v1.2.3", "https://github.example/archive.tar.gz"); got != "https://github.example/archive.tar.gz" {
		t.Fatalf("fallback download URL = %q", got)
	}
}

func TestReleaseSourceOverridesGitHub(t *testing.T) {
	t.Setenv(releaseAPIBaseURLEnv, "https://mirror.example/api/")
	t.Setenv(releaseDownloadBaseURLEnv, "https://mirror.example/releases/")

	if got := releaseAPIBaseURL(); got != "https://mirror.example/api" {
		t.Fatalf("release API base URL = %q", got)
	}
	if got := releaseAssetDownloadURL("multica-cli-1.2.3-linux-amd64.tar.gz", "v1.2.3", "https://github.example/archive.tar.gz"); got != "https://mirror.example/releases/v1.2.3/multica-cli-1.2.3-linux-amd64.tar.gz" {
		t.Fatalf("mirror download URL = %q", got)
	}
}

// The repository is what decides which releases an installed binary can see.
// If any lookup points at upstream, an update replaces this build with one
// that lacks its features — the exact regression the fork distribution exists
// to prevent.
func TestReleaseRepositoryPinnedToThisDistribution(t *testing.T) {
	if ReleaseRepository != "zzttzzmyswy/multica" {
		t.Fatalf("ReleaseRepository = %q, want the self-host distribution repository", ReleaseRepository)
	}
	if got, want := ReleaseWebURL(), "https://github.com/zzttzzmyswy/multica"; got != want {
		t.Fatalf("ReleaseWebURL() = %q, want %q", got, want)
	}
	// The mirror overrides change the host only. Losing the repository from
	// the path would turn a documented mirror into a silent upstream lookup.
	t.Setenv(releaseAPIBaseURLEnv, "")
	for _, path := range []string{
		releaseAPIPath("latest"),
		releaseAPIPath("tags/v1.2.3"),
	} {
		if !strings.HasPrefix(path, "/repos/zzttzzmyswy/multica/releases/") {
			t.Fatalf("release API path %q does not target the distribution repository", path)
		}
	}
}

// The newest-build lookup must read the LIST endpoint, never
// `/releases/latest`: every distribution release is a prerelease and GitHub
// excludes prereleases from `latest`, so that endpoint 404s for this repository
// no matter how many builds are published. A CLI that asks `latest` and gives up
// is the reported defect; this test fails if it comes back.
func TestFetchLatestReleaseReadsTheListNotTheLatestEndpoint(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")

		// GitHub's real answer for a prerelease-only repository.
		if strings.HasSuffix(r.URL.Path, "/releases/latest") {
			http.NotFound(w, r)
			return
		}
		if !strings.Contains(r.URL.Path, "/releases") {
			http.NotFound(w, r)
			return
		}
		if r.URL.Query().Get("per_page") == "" {
			t.Errorf("list request omitted per_page: %s", r.URL.String())
			http.NotFound(w, r)
			return
		}
		_ = json.NewEncoder(w).Encode([]GitHubRelease{
			{
				TagName:    "v0.9.0-myswy.1",
				Prerelease: true,
				Assets:     assetsFor("0.9.0-myswy.1"),
			},
			{
				TagName:    "v0.9.0-myswy.2",
				Prerelease: true,
				Assets:     assetsFor("0.9.0-myswy.2"),
			},
		})
	}))
	defer srv.Close()
	t.Setenv(releaseAPIBaseURLEnv, srv.URL)

	got, err := FetchLatestRelease()
	if err != nil {
		t.Fatalf("FetchLatestRelease() error = %v", err)
	}
	if got.TagName != "v0.9.0-myswy.2" {
		t.Fatalf("release tag = %q, want v0.9.0-myswy.2", got.TagName)
	}
}

// A tag that contains the distribution suffix but is not a well-formed
// vX.Y.Z-myswy.N release must never win newest-build selection, no matter how
// high it sorts. The malformed entries here all outrank the one valid release,
// so any lenient parse (truncating "-extra", splitting off a 4th component,
// coercing a non-numeric or empty build to 0) makes this test select them.
func TestFetchLatestReleaseSkipsMalformedTagsEvenWhenTheySortHighest(t *testing.T) {
	releases := []GitHubRelease{
		// Suffix present, trailing junk: the exact tag an earlier parser read as
		// 99.0.0 build 1 and then requested.
		{TagName: "v99.0.0-myswy.1-extra", Assets: []GitHubReleaseAsset{
			{Name: "multica-cli-99.0.0-myswy.1-extra-linux-amd64.tar.gz"},
		}},
		// Extra numeric component.
		{TagName: "v98.0.0-myswy.1.2", Assets: []GitHubReleaseAsset{
			{Name: "multica-cli-98.0.0-myswy.1.2-linux-amd64.tar.gz"},
		}},
		// Empty build.
		{TagName: "v97.0.0-myswy.", Assets: []GitHubReleaseAsset{
			{Name: "multica-cli-97.0.0-myswy.-linux-amd64.tar.gz"},
		}},
		// Non-numeric build.
		{TagName: "v96.0.0-myswy.x", Assets: []GitHubReleaseAsset{
			{Name: "multica-cli-96.0.0-myswy.x-linux-amd64.tar.gz"},
		}},
		// Signed build.
		{TagName: "v95.0.0-myswy.-1", Assets: []GitHubReleaseAsset{
			{Name: "multica-cli-95.0.0-myswy.-1-linux-amd64.tar.gz"},
		}},
		// Draft, otherwise well-formed.
		{TagName: "v94.0.0-myswy.1", Draft: true, Assets: assetsFor("94.0.0-myswy.1")},
		// Well-formed, but the only archive is for another platform.
		{TagName: "v93.0.0-myswy.1", Assets: assetsForPlatform("93.0.0-myswy.1", "darwin", "arm64")},
		// Well-formed, but its archive names a different version.
		{TagName: "v92.0.0-myswy.1", Assets: []GitHubReleaseAsset{
			{Name: "multica-cli-0.9.0-myswy.1-linux-amd64.tar.gz"},
		}},
		// Well-formed, but publishes only the versionless legacy archive, which
		// cannot be tied to this tag.
		{TagName: "v91.0.0-myswy.1", Assets: []GitHubReleaseAsset{
			{Name: "multica_linux_amd64.tar.gz"},
		}},
		// The only release that is actually installable.
		{TagName: "v0.9.0-myswy.2", Assets: assetsFor("0.9.0-myswy.2")},
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(releases)
	}))
	defer srv.Close()
	t.Setenv(releaseAPIBaseURLEnv, srv.URL)

	got, err := FetchLatestRelease()
	if err != nil {
		t.Fatalf("FetchLatestRelease() error = %v", err)
	}
	if got.TagName != "v0.9.0-myswy.2" {
		t.Fatalf("selected %q; every higher-ranked entry is malformed, a draft, for another platform, or carries the wrong archive", got.TagName)
	}
}

// One unusable entry must not hide the valid ones around it: selection has to
// skip each bad release individually rather than stop at the first.
func TestFetchLatestReleaseSkipsBadEntriesIndividually(t *testing.T) {
	releases := []GitHubRelease{
		{TagName: "v0.9.0-myswy.3", Draft: true, Assets: assetsFor("0.9.0-myswy.3")},
		{TagName: "v0.9.0-myswy.1-extra", Assets: []GitHubReleaseAsset{
			{Name: "multica-cli-0.9.0-myswy.1-extra-linux-amd64.tar.gz"},
		}},
		{TagName: "v0.9.0-myswy.2", Assets: assetsFor("0.9.0-myswy.2")},
		{TagName: "v0.9.0-myswy.", Assets: []GitHubReleaseAsset{
			{Name: "multica-cli-0.9.0-myswy.-linux-amd64.tar.gz"},
		}},
		{TagName: "v0.9.0-myswy.1", Assets: assetsFor("0.9.0-myswy.1")},
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(releases)
	}))
	defer srv.Close()
	t.Setenv(releaseAPIBaseURLEnv, srv.URL)

	got, err := FetchLatestRelease()
	if err != nil {
		t.Fatalf("FetchLatestRelease() error = %v", err)
	}
	if got.TagName != "v0.9.0-myswy.2" {
		t.Fatalf("selected %q, want v0.9.0-myswy.2", got.TagName)
	}
}

func assetsFor(version string) []GitHubReleaseAsset {
	return []GitHubReleaseAsset{{
		Name:               ReleaseAssetName(version, "linux", "amd64"),
		BrowserDownloadURL: "https://example.invalid/" + version,
	}}
}

// assetsForPlatform lets a table test pin an arbitrary platform.
func assetsForPlatform(version, goos, goarch string) []GitHubReleaseAsset {
	return []GitHubReleaseAsset{{
		Name:               ReleaseAssetName(version, goos, goarch),
		BrowserDownloadURL: "https://example.invalid/" + version,
	}}
}

// Newest-build selection has to skip four kinds of entry that a real fork
// repository contains: upstream tags synced alongside the distribution's own,
// prereleases for other platforms, drafts, and releases without the archive this
// platform installs. Picking any of them either installs a binary without this
// distribution's features or fails at download time.
func TestFetchLatestReleaseSelectsNewestUsableDistributionBuild(t *testing.T) {
	releases := []GitHubRelease{
		// Upstream tag synced into the same repository, highest version of all.
		{TagName: "v9.9.9", Assets: assetsFor("9.9.9")},
		// Newer distribution build that only built another platform.
		{TagName: "v0.10.0-myswy.1", Assets: assetsForPlatform("0.10.0-myswy.1", "darwin", "arm64")},
		{TagName: "v0.9.0-myswy.3", Assets: assetsFor("0.9.0-myswy.3")},
		{TagName: "v0.9.0-myswy.10", Assets: assetsFor("0.9.0-myswy.10")},
		// A distribution tag with no assets at all.
		{TagName: "v0.9.0-myswy.11"},
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if strings.HasSuffix(r.URL.Path, "/releases/latest") {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(releases[0]) // what a fork's latest could be
			return
		}
		_ = json.NewEncoder(w).Encode(releases)
	}))
	defer srv.Close()
	t.Setenv(releaseAPIBaseURLEnv, srv.URL)

	got, err := FetchLatestRelease()
	if err != nil {
		t.Fatalf("FetchLatestRelease() error = %v", err)
	}
	// 0.9.0-myswy.10 beats myswy.3 numerically; 0.10.0-myswy.1 and 0.9.0-myswy.11
	// are excluded for having no linux/amd64 archive; v9.9.9 is not a
	// distribution tag.
	if got.TagName != "v0.9.0-myswy.10" {
		t.Fatalf("selected %q, want v0.9.0-myswy.10", got.TagName)
	}
}

func TestFetchLatestReleaseReportsWhenNothingIsInstalled(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode([]GitHubRelease{
			{TagName: "v9.9.9", Assets: assetsFor("9.9.9")}, // upstream only
		})
	}))
	defer srv.Close()
	t.Setenv(releaseAPIBaseURLEnv, srv.URL)

	_, err := FetchLatestRelease()
	if err == nil {
		t.Fatal("FetchLatestRelease() must fail when only upstream tags exist")
	}
	if !strings.Contains(err.Error(), "no published distribution build") {
		t.Fatalf("error should say there is no distribution build, got: %v", err)
	}
}

func TestIsDistributionTagRejectsUpstreamTags(t *testing.T) {
	distribution := []string{"v0.9.0-myswy.1", "v1.2.3-myswy.10"}
	// A tag without the v is not what this distribution's workflow publishes,
	// and release selection reads API tags verbatim. Pinned input may omit it,
	// but that path normalizes before it reaches this predicate.
	rejected := []string{
		"0.9.0-myswy.1",
		"v0.9.0",
		"v1.2.3",
		"v0.2.15-235-gdaf0e935",
		"",
		// Contains the suffix, but is not a version this distribution publishes.
		"v99.0.0-myswy.1-extra",
		"v0.9.0-myswy.1.2",
		"v0.9.0-myswy.",
		"v0.9.0-myswy.x",
		"v0.9.0-myswy.-1",
	}

	for _, tag := range distribution {
		if !IsDistributionTag(tag) {
			t.Fatalf("IsDistributionTag(%q) = false, want true", tag)
		}
	}
	for _, tag := range rejected {
		if IsDistributionTag(tag) {
			t.Fatalf("IsDistributionTag(%q) = true; it must never be selected", tag)
		}
	}
}

func TestParseDistributionVersion(t *testing.T) {
	tests := []struct {
		tag  string
		want [4]int
		ok   bool
	}{
		{"v0.9.0-myswy.1", [4]int{0, 9, 0, 1}, true},
		{"v0.9.0-myswy.10", [4]int{0, 9, 0, 10}, true},
		{"v1.2.3-myswy.0", [4]int{1, 2, 3, 0}, true},
		// Four non-empty numeric components, all of them required.
		{"v0.9.0-myswy.1-extra", [4]int{}, false},
		{"v0.9.0-myswy.1.2", [4]int{}, false},
		{"v0.9.0-myswy.", [4]int{}, false},
		{"v0.9.0-myswy.x", [4]int{}, false},
		{"v0.9.0-myswy.-1", [4]int{}, false},
		{"v0.9.0-myswy.+1", [4]int{}, false},
		{"v0.9..0-myswy.1", [4]int{}, false},
		{"v0.9.0-myswy.99999999999999999999", [4]int{}, false}, // overflows int
		{"v0.9.0", [4]int{}, false},
		{"v0.9-myswy.1", [4]int{}, false},
		{"0.9.0-myswy.10", [4]int{}, false},
		{"v0.2.15-235-gdaf0e935", [4]int{}, false},
	}
	for _, tt := range tests {
		got, ok := parseDistributionVersion(tt.tag)
		if ok != tt.ok {
			t.Fatalf("parseDistributionVersion(%q) ok = %v, want %v", tt.tag, ok, tt.ok)
		}
		if ok && got != tt.want {
			t.Fatalf("parseDistributionVersion(%q) = %v, want %v", tt.tag, got, tt.want)
		}
	}
}

func TestVersionGreaterOrdersBuildNumbersNumerically(t *testing.T) {
	// The distinction a lexical comparison gets wrong: "10" sorts before "9" as
	// text but is the newer build.
	if !versionGreater([4]int{0, 9, 0, 10}, [4]int{0, 9, 0, 9}) {
		t.Fatal("myswy.10 must be newer than myswy.9")
	}
	if versionGreater([4]int{0, 9, 0, 9}, [4]int{0, 9, 0, 10}) {
		t.Fatal("myswy.9 must not be newer than myswy.10")
	}
	if !versionGreater([4]int{0, 10, 0, 1}, [4]int{0, 9, 0, 7}) {
		t.Fatal("a newer base version must win regardless of build number")
	}
	if versionGreater([4]int{0, 9, 0, 1}, [4]int{0, 9, 0, 1}) {
		t.Fatal("equal versions must not compare as greater")
	}
}

// Newest-build selection must ask this distribution's repository, and must do it
// through the list endpoint. This replaces an earlier version of the test that
// asserted a `/releases/latest` request: that assertion described the defect
// (prereleases are invisible to `latest`) rather than the requirement.
func TestFetchLatestReleaseUsesDistributionRepository(t *testing.T) {
	rec := &releaseRecorder{
		releases: []GitHubRelease{{
			TagName:    "v9.8.7-myswy.7",
			Prerelease: true,
			Assets:     assetsFor("9.8.7-myswy.7"),
		}},
	}
	srv := rec.server(t)
	t.Setenv(releaseAPIBaseURLEnv, srv.URL)

	got, err := FetchLatestRelease()
	if err != nil {
		t.Fatalf("FetchLatestRelease() error = %v", err)
	}
	if got.TagName != "v9.8.7-myswy.7" {
		t.Fatalf("release tag = %q, want v9.8.7-myswy.7", got.TagName)
	}

	paths := rec.recorded()
	if len(paths) != 1 {
		t.Fatalf("newest-build lookup made %d requests, want 1: %v", len(paths), paths)
	}
	// The path must be the collection, with the distribution repository in it.
	if !strings.HasPrefix(paths[0], "/repos/zzttzzmyswy/multica/releases") {
		t.Fatalf("newest-build lookup path = %q, want the distribution release list", paths[0])
	}
	if strings.Contains(paths[0], "/latest") {
		t.Fatalf("newest-build lookup must not use /releases/latest (prereleases are invisible there): %q", paths[0])
	}
}

func TestFetchReleaseByTagUsesDistributionRepository(t *testing.T) {
	rec := &releaseRecorder{tags: map[string]string{"v1.2.3": "v1.2.3"}}
	srv := rec.server(t)
	t.Setenv(releaseAPIBaseURLEnv, srv.URL)

	got, err := FetchReleaseByTag("1.2.3")
	if err != nil {
		t.Fatalf("FetchReleaseByTag() error = %v", err)
	}
	if got.TagName != "v1.2.3" {
		t.Fatalf("release tag = %q, want v1.2.3", got.TagName)
	}

	paths := rec.recorded()
	if len(paths) != 1 {
		t.Fatalf("by-tag lookup made %d requests, want 1: %v", len(paths), paths)
	}
	// A missing "v" is normalized, so the operator can pass 1.2.3 or v1.2.3.
	if want := "/repos/zzttzzmyswy/multica/releases/tags/v1.2.3"; paths[0] != want {
		t.Fatalf("by-tag lookup path = %q, want %q", paths[0], want)
	}
}

// A lookup that fails must report the failure, not retry somewhere else. An
// automatic fallback to upstream is indistinguishable from a successful
// update until the operator notices the missing features.
func TestFailedLookupDoesNotReachAnotherRepository(t *testing.T) {
	rec := &releaseRecorder{} // every path 404s
	srv := rec.server(t)
	t.Setenv(releaseAPIBaseURLEnv, srv.URL)

	if _, err := FetchLatestRelease(); err == nil {
		t.Fatal("FetchLatestRelease() must fail when the release is absent")
	}
	if _, err := FetchReleaseByTag("v1.2.3"); err == nil {
		t.Fatal("FetchReleaseByTag() must fail when the release is absent")
	}

	for _, path := range rec.recorded() {
		if !strings.HasPrefix(path, "/repos/zzttzzmyswy/multica/") {
			t.Fatalf("a failed lookup requested %q, which is outside the distribution repository", path)
		}
	}
	if len(rec.recorded()) == 0 {
		t.Fatal("expected the fake API to have been asked at least once")
	}
}

// An archive and its checksum manifest must come from the same release of the
// same repository: verifying a checksum published by a different project would
// validate nothing.
func TestArchiveAndChecksumComeFromSameRelease(t *testing.T) {
	const tag = "v0.9.0-myswy.1"
	archive := ReleaseAssetName("0.9.0-myswy.1", "linux", "amd64")

	archiveURL := releaseAssetDownloadURL(archive, tag, ReleaseArchiveURL(tag, archive))
	checksumURL := releaseAssetDownloadURL(ChecksumManifestName, tag, ReleaseArchiveURL(tag, ChecksumManifestName))

	wantPrefix := "https://github.com/zzttzzmyswy/multica/releases/download/v0.9.0-myswy.1/"
	for name, got := range map[string]string{"archive": archiveURL, "checksums": checksumURL} {
		if !strings.HasPrefix(got, wantPrefix) {
			t.Fatalf("%s URL = %q, want prefix %q", name, got, wantPrefix)
		}
	}
	// The suffix carries the distribution tag's prerelease component, which is
	// what makes the versioned asset name unique across releases.
	if archive != "multica-cli-0.9.0-myswy.1-linux-amd64.tar.gz" {
		t.Fatalf("archive name = %q, want the myswy-suffixed versioned name", archive)
	}
}

// The two mirror overrides must keep redirecting both the archive and the
// checksum manifest, or a mirror install would verify against a manifest it
// never downloaded.
func TestMirrorOverrideAppliesToArchiveAndChecksum(t *testing.T) {
	t.Setenv(releaseDownloadBaseURLEnv, "https://mirror.example/releases")
	const tag = "v1.2.3"

	archive := ReleaseAssetName("1.2.3", "linux", "arm64")
	got := releaseAssetDownloadURL(archive, tag, "https://fallback.example/"+archive)
	want := "https://mirror.example/releases/v1.2.3/" + archive
	if got != want {
		t.Fatalf("mirror archive URL = %q, want %q", got, want)
	}

	got = releaseAssetDownloadURL(ChecksumManifestName, tag, "https://fallback.example/"+ChecksumManifestName)
	want = "https://mirror.example/releases/v1.2.3/" + ChecksumManifestName
	if got != want {
		t.Fatalf("mirror checksum URL = %q, want %q", got, want)
	}
}

// A build with no formula must refuse the brew route rather than invent one.
func TestUpdateViaBrewFailsClosedWithoutFormula(t *testing.T) {
	original := BrewFormulaName
	BrewFormulaName = ""
	t.Cleanup(func() { BrewFormulaName = original })

	if _, err := UpdateViaBrew(); err == nil {
		t.Fatal("UpdateViaBrew() must fail when the build publishes no formula")
	} else if !errors.Is(err, ErrNoBrewFormula) {
		t.Fatalf("UpdateViaBrew() error = %v, want ErrNoBrewFormula", err)
	}
}

// The release archive name must carry the distribution tag's suffix. A name
// built from a truncated version would make `multica update` look for an asset
// no release publishes.
func TestReleaseAssetNameKeepsDistributionSuffix(t *testing.T) {
	tests := []struct {
		version string
		goos    string
		goarch  string
		want    string
	}{
		{"0.9.0-myswy.1", "linux", "amd64", "multica-cli-0.9.0-myswy.1-linux-amd64.tar.gz"},
		{"v0.9.0-myswy.2", "darwin", "arm64", "multica-cli-0.9.0-myswy.2-darwin-arm64.tar.gz"},
		{"1.2.3", "windows", "amd64", "multica-cli-1.2.3-windows-amd64.zip"},
	}
	for _, tt := range tests {
		if got := ReleaseAssetName(tt.version, tt.goos, tt.goarch); got != tt.want {
			t.Fatalf("ReleaseAssetName(%q, %q, %q) = %q, want %q", tt.version, tt.goos, tt.goarch, got, tt.want)
		}
	}
}

// A myswy build carries a prerelease suffix, so it is deliberately not a
// "release version" by the upstream definition and the daemon's unattended
// poller stays off. Pinning is the supported update path instead; this test
// records that intentional behavior so a later "fix" to IsReleaseVersion
// cannot silently re-enable unattended upstream polling for these builds.
func TestDistributionVersionIsNotAnUnattendedUpdateCandidate(t *testing.T) {
	for _, v := range []string{"v0.9.0-myswy.1", "0.9.0-myswy.1", "v0.10.0-myswy.12"} {
		if IsReleaseVersion(v) {
			t.Fatalf("IsReleaseVersion(%q) = true; a distribution build must not auto-poll unattended", v)
		}
		// It also must not compare as "newer", so an accidental comparison
		// against an upstream release cannot look like an upgrade.
		if IsNewerVersion(v, "v0.9.0") {
			t.Fatalf("IsNewerVersion(%q, v0.9.0) = true; a suffixed build must not rank above a bare release", v)
		}
	}
}
