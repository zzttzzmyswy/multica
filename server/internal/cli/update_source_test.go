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

func TestFetchLatestReleaseUsesDistributionRepository(t *testing.T) {
	rec := &releaseRecorder{latestTag: "v9.8.7"}
	srv := rec.server(t)
	t.Setenv(releaseAPIBaseURLEnv, srv.URL)

	got, err := FetchLatestRelease()
	if err != nil {
		t.Fatalf("FetchLatestRelease() error = %v", err)
	}
	if got.TagName != "v9.8.7" {
		t.Fatalf("release tag = %q, want v9.8.7", got.TagName)
	}

	paths := rec.recorded()
	if len(paths) != 1 {
		t.Fatalf("latest lookup made %d requests, want 1: %v", len(paths), paths)
	}
	if want := "/repos/zzttzzmyswy/multica/releases/latest"; paths[0] != want {
		t.Fatalf("latest lookup path = %q, want %q", paths[0], want)
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
