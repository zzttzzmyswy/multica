package daemon

import (
	"io"
	"log/slog"
	"strings"
	"testing"

	"github.com/multica-ai/multica/server/internal/cli"
)

// A daemon whose CLI was installed through Homebrew must not run
// `brew upgrade` for a formula this build does not publish, and must not
// replace the keg's binary either. Both options corrupt the install; the only
// correct outcome is an explicit error telling the operator where to get the
// build from.
//
// The failure has to be visible in the returned error, because updateReportResult
// is how the server-side UI learns that an update did not happen. A silent
// success would leave the operator believing the daemon was current.
func TestRunUpdate_RefusesBrewInstallWithoutOwnFormula(t *testing.T) {
	originalIsBrewInstall := isBrewInstall
	originalFormula := cli.BrewFormulaName
	t.Cleanup(func() {
		isBrewInstall = originalIsBrewInstall
		cli.BrewFormulaName = originalFormula
	})

	isBrewInstall = func() bool { return true }
	cli.BrewFormulaName = "" // this distribution publishes no tap

	d := &Daemon{logger: slog.New(slog.NewTextHandler(io.Discard, nil))}

	out, err := d.runUpdate("v0.9.0-myswy.2")
	if err == nil {
		t.Fatalf("runUpdate() must fail for a brew install with no formula; got output %q", out)
	}

	msg := err.Error()
	// The message must name where the build actually comes from, so an
	// operator can finish the update by hand.
	if !strings.Contains(msg, "zzttzzmyswy/multica") {
		t.Fatalf("error must name the release repository, got: %s", msg)
	}
	if !strings.Contains(msg, "v0.9.0-myswy.2") {
		t.Fatalf("error must name the requested version, got: %s", msg)
	}
	// And it must not send the operator to upstream's tap, which would install
	// a build without this distribution's features.
	if strings.Contains(msg, "multica-ai/tap") {
		t.Fatalf("error must not point at the upstream Homebrew tap: %s", msg)
	}
}
