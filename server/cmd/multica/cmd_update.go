package main

import (
	"fmt"
	"os"
	"runtime"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/multica-ai/multica/server/internal/cli"
)

var updateDownloadTimeout time.Duration = cli.DefaultUpdateDownloadTimeout

// updateTargetVersion pins the update to an exact release tag instead of the
// moving `latest`. This distribution is installed from its own releases and
// `latest` can drift, so an operator who needs a specific build (a rollback, a
// reproducible deployment) must be able to name it.
var updateTargetVersion string

var updateCmd = &cobra.Command{
	Use:   "update",
	Short: "Update multica to the latest build from this project's releases",
	Long: "Update multica from this build's own release repository (" + cli.ReleaseRepository + ").\n\n" +
		"Without --version the newest published release is installed. With --version an\n" +
		"exact tag is installed, which is how you roll back or pin a deployment.",
	RunE: runUpdate,
}

func init() {
	updateCmd.Flags().DurationVar(&updateDownloadTimeout, "download-timeout", cli.DefaultUpdateDownloadTimeout, "Maximum time to wait for the release archive download")
	updateCmd.Flags().StringVar(&updateTargetVersion, "version", "", "Install this exact release tag instead of the latest one")
}

func runUpdate(_ *cobra.Command, _ []string) error {
	if updateDownloadTimeout <= 0 {
		return fmt.Errorf("download timeout must be greater than zero")
	}

	fmt.Fprintf(os.Stderr, "Current version: %s (commit: %s, built: %s)\n", version, commit, date)

	pinned := strings.TrimSpace(updateTargetVersion) != ""

	// Resolve the target release. A pinned tag is fetched directly so a pinned
	// install never consults `latest`; the unpinned path needs it to decide
	// whether there is anything to do.
	var target *cli.GitHubRelease
	var err error
	if pinned {
		target, err = cli.FetchReleaseByTag(updateTargetVersion)
		if err != nil {
			// A pinned target that cannot be resolved is a hard failure: the
			// operator named one version and installing a different one would
			// be worse than doing nothing.
			return fmt.Errorf("could not resolve release %s from %s: %w", updateTargetVersion, cli.ReleaseRepository, err)
		}
	} else {
		target, err = cli.FetchLatestRelease()
		if err != nil {
			// The list-based lookup can legitimately find nothing (no build
			// published yet for this platform). Say so, and give the pinned
			// form, instead of a bare "release API returned 404".
			return fmt.Errorf("could not find a published distribution build in %s: %w\n"+
				"Install one exact version instead:\n  multica update --version vX.Y.Z-myswy.N\n"+
				"List the available tags at %s/releases",
				cli.ReleaseRepository, err, cli.ReleaseWebURL())
		}
	}

	if !pinned {
		currentVer := strings.TrimPrefix(version, "v")
		latestVer := strings.TrimPrefix(target.TagName, "v")
		if currentVer == latestVer {
			fmt.Fprintln(os.Stderr, "Already up to date.")
			return nil
		}
	}
	fmt.Fprintf(os.Stderr, "Target version:  %s (from %s)\n\n", target.TagName, cli.ReleaseRepository)

	// Detect installation method and update accordingly. A Homebrew install
	// must go through brew, because replacing the binary underneath a keg
	// breaks `brew upgrade` and `brew doctor`.
	if cli.IsBrewInstall() {
		if cli.BrewFormulaName == "" {
			return cli.BrewInstallBlockedError(target.TagName, runtime.GOOS, runtime.GOARCH)
		}
		fmt.Fprintln(os.Stderr, "Updating via Homebrew...")
		output, err := cli.UpdateViaBrew()
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s\n", output)
			return fmt.Errorf("brew upgrade failed: %w\nYou can try manually: brew upgrade %s", err, cli.BrewFormulaName)
		}
		fmt.Fprintln(os.Stderr, "Update complete.")
		return nil
	}

	fmt.Fprintf(os.Stderr, "Downloading %s from %s...\n", target.TagName, cli.ReleaseRepository)
	output, err := cli.UpdateViaDownloadWithTimeout(target.TagName, updateDownloadTimeout)
	if err != nil {
		return fmt.Errorf("update failed: %w", err)
	}
	fmt.Fprintf(os.Stderr, "%s\nUpdate complete.\n", output)
	return nil
}
