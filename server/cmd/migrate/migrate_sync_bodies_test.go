package main

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"

	"github.com/multica-ai/multica/server/internal/migrations"
)

// TestRenumberedMigrationBodiesAreTheUpstreamBytes is the half of a renumber a
// name check cannot see. A sync copies upstream's migration bytes and changes
// only the numeric prefix, because the SQL body is what makes the migration mean
// what upstream meant. A body that drifts here — an accidental edit, a rename
// applied to the neighbouring file, a conflict resolution that pasted the other
// side — gives a fresh install a schema an upgraded database never had.
//
// The digests were recorded from the reviewed sync tree, not computed at test
// time: a digest derived from the file it checks proves nothing. A future sync
// replaces the whole map, so each reviewed value is a deliberate act.
var renumberedUpstreamBodySHA256 = map[string]string{
	"701_autopilot_run_idempotency_key":             "2421d02f11aa02531baebad3dcd95e39d24e8bcc1875d2531127dbfa3a1626f2",
	"702_autopilot_run_idempotency_key_idx":         "adfc330e870a5ae280b2b8ece3d7f55856241d00962aabd60feef8531e81a484",
	"703_member_guest_role":                         "fa8d25997dd56a647aff92fb5aff8eaaecf1bb7131ab9afa138189e26f1534ad",
	"704_member_search_access":                      "81c6af206cc1631ae3f53eb13f29ad8e6468300449b6a5f19ca47ca65af6632a",
	"705_member_search_access_pkey_index":           "ec2a582b65dc1585dc5d354c80fc80f2c5375b6cfb3eb18d59529447d0dca296",
	"706_member_search_access_pkey":                 "1741c475ad657e05c0a185bee0bbf8bae355b3906dca181f65b4f345d991b9ec",
	"707_doc_comment":                               "13a64f92de132380a8899d09c1ba2cff161d0bb46f48aaf483df8c0dc39a72e9",
	"708_doc_comment_pkey_index":                    "cb0f7a95a5dea730dc3142ed904e2e30d5654e2e1f0e8489f1e64dcf4cbfbba7",
	"709_doc_comment_pkey":                          "0a785b09f67e35eeb620a116a0db8166725c1357f68229afd234367ca91946f8",
	"710_doc_comment_doc_idx":                       "5e9eebb0d52f1880e6b5d6d62f80585a533932a8a7ce5e90726164dfb440f49f",
	"711_doc_comment_workspace_idx":                 "62e69e02c2bf0ee63618182ad8e34b24217a4c43a24255500cb81a1dd41e17c0",
	"712_attachment_workspace_size_idx":             "ae99516224933567ff629a59a4593c03a2b5a089ceeb0d5cda87963816f78763",
	"713_drop_attachment_workspace_index":           "9a8f0c36afc77b736a40c712bc8f1555d43df8488adacea3eef073770965548e",
	"714_autopilot_quota_limit_notice":              "1f8d1b2d42c7fe4a03d260820817438d0cbf89861fec8d3c2dcc6da1d3fd5347",
	"715_dashboard_range_view":                      "5b398cff587417085f7716db2855b7010ff5b7fab3db3d3c54c976705fd40b4b",
	"716_dashboard_range_view_scope_idx":            "aea0602135525231b633915f0821433a17d3e7a303ba6fa2f831d9d75d3d2a8b",
	"717_doc_collab":                                "4f549627e7cd30cca591b424f701c1cfca831faee0a4c2e78c8d0aca5ee2c3fe",
	"718_doc_collab_state_pkey_index":               "26f4bda5d72f38553cb9f266c22bb08e5772b7a2aa6ffbc3b5a2d4ccfa671c42",
	"719_doc_collab_state_pkey":                     "3591dc7fca88c049f4890c5bad3d0b64dcbe4803ab8f5320d22f07bce83b8d34",
	"720_doc_revision_pkey_index":                   "0730ebeff1a5ea638edfa69e2a5d4a00365053e64ea7f9bc403986ccba83f83b",
	"721_doc_revision_pkey":                         "a86514f7ba5367a7705165a0bc07f972a314091f381728a72215c6a587202365",
	"722_auto_archive_prompt":                       "49587f1efe9c7bb89a5c3ae0c45873db5999d3fb722b670619029efe4dd33486",
	"723_remote_app_connection":                     "0666c7eae1abfb7dbfc5ce737cd2492685c563f50a0ec4a6f7ec7442efd93710",
	"724_remote_app_oauth_client_idx":               "1d00a39e285b5d491421ec1656080617570e2284f4ec200c1f1682be3347cacf",
	"725_remote_app_connection_owner_idx":           "f95a28d7b83c99a7d386123b5ff7d0300fe3d4ba915c7cc62495a7efb5a92e16",
	"726_auto_archive_agent_trigger_prompt":         "abb16d7931e2dd82de2d8c7cefce06d0cdfd8bc3167bd0cf4167ec3e99bca8cc",
	"727_issue_description_collab":                  "7c81b1e13fe6da481b39cbb130347fdc0d919db03221bc7432b588df06175cc7",
	"728_issue_description_collab_state_pkey_index": "31043e6ac38cdb6228bc175e19e9f77e56e89088741e2e7eb3d9a2ccf7b4bd99",
	"729_issue_description_collab_state_pkey":       "f16061aaf89e4ea7b197183d04a86a1ce8ae3895cbad7c12d1c1b3e08e27a8bb",
	"730_issue_description_revision_pkey_index":     "c5bf20083a3d6a27a36fbdf58fb9a5bb4145409880c3a51deb701fa9bb89d0c3",
	"731_issue_description_revision_pkey":           "be601dc3ac4d30fd131c25da4ae64cdf547e38b8c6f07394de95ebdcc7fe4df8",
	"732_app_account_requests":                      "7902c5a13b818f2b906ac76afad11c0d7e8dd2d05549ca8d30323add9c00ff6a",
	"733_remote_app_connection_workspace_idx":       "847af3637a2c74f281d92d423504d454417cbe34b6fd26c33afd415246371db0",
	"734_drop_remote_app_connection_owner_idx":      "a61a5fd5dffc3c84e856d765018f13e0a971cb832da78a94a9f5a921e3254834",
	"735_skill_revision":                            "d458e51d248e4ab8f7d6f6cbcd9d136896f8b481313e736ed792b23ae5294523",
	"736_comment_idempotency_receipt":               "9968f1a87dd45f6b7aea4fe6f7859bfb924244968acd9c1534fd31ffa3bf955d",
	"737_comment_idempotency_receipt_key":           "1b7af20f8a6093a8d596815697bda3f1f5f679e603920142cff4223f7bb9f3c6",
	"738_comment_idempotency_receipt_created":       "459dcf7272aaf152474824ac6fc4e848b5aad64ebfade9dbf2019fcae8ac6c06",
	"739_task_usage_hourly_squad_col":               "370535ad615ba85c21ffc449297f1eda08cef540d2b26ebedce8871d346e29aa",
	"740_task_usage_hourly_squad_uq_idx":            "1be46c162265a31d17d351a029ac02c8628854f27fac813f632ea9ba70bd9679",
	"741_task_usage_hourly_dirty_squad_uq_idx":      "12e94f08d223c35c42272d18f9f247a96fa1e8110aa166e749ede8fb69af2822",
	"742_task_usage_hourly_workspace_squad_idx":     "f55125249d4abb4e7627e32b2da1e040f8bc4a562e98a595d768f91d6215a252",
	"743_task_usage_hourly_squad_pipeline":          "82cd0319f69220a4bcc0a7fe1a4ca65b6cb93830060640c1b6a4826bcda05c58",
	"744_task_usage_hourly_drop_legacy_key":         "3b76bc03eb0cd19d7fe8cbb80e3859088a60780298240c3d1d6f8e1c35691ea6",
	"745_task_usage_hourly_dirty_drop_legacy_key":   "1c851cf8eb55c9bc8cb2b0c44d036e0e22d612d5ed067417293df021972dc90d",
	"746_task_usage_hourly_squad_rollback_merge":    "edf1a873ced448d2f2809cbe88ecc5bce908ff81fc2627a50f263b8058672a6a",
	"747_issue_blocker":                             "51a3bedcc901e510dc755949d35df119de6cda92b369e95687ffbff6fe0f8069",
	"748_issue_blocker_unique":                      "f68b89ff3df27db1b4fd542945db75d607599e35e67dea7b0af7346383945c78",
	"749_issue_blocker_reverse":                     "494b607bcd7c7ace086c930bc32ac61efa9b57ed431c776e5f198b5625d70c3b",
	"750_issue_blocker_rules":                       "a6040388f4f3793d8692b2f3335b4898ee3272141d143ebf0780ab4ef972ec77",
	"751_squad_handoff_mode":                        "c6fb3c8a3272ccbe7291e33fcf4ad79317a87ed2c1ce70b7b53e5cd3b5ce0147",
	"752_app_tool_call_quota_period":                "ac3fc0738682d366d3bd88f5eca1d0066e54348f02a1fd2e4b3ee591e9d14994",
	"753_app_tool_call_quota_period_scope_idx":      "228f78bdd2f756a01b5be6c72379240f40490cca2428665f784ef9343e220d4c",
	"754_app_tool_call_quota_columns":               "952e9975f461039b6a6c4aed11308cc411da3f0186636766a179d2a2d1d18bd2",
	"755_app_tool_call_workspace_metered_idx":       "aaf407b2cf98ed28dc2731e825b37e291628fead31e754e2acbc440838d677e5",
	"756_doc_comment_agent_runs":                    "f6d330b25b2ea8e21a65951081436b1829496645a80e0ed46851de800a97e409",
	"757_agent_task_queue_doc_idx":                  "9891f0c2fbf370015de3cbbe8245190c059ec2e6a6877b633221325a6fb1a36e",
	"758_issue_stage_blockers_skip_top_level":       "5cf01aa882eba4e021fd38fbf2e69b4805bf1d2ccda7dfe1a7f3b261994f6057",
	"759_task_usage_hourly_rollup_hour_key":         "62fd9d4e0dc6cf8bf133b631d65d2874349335d7027e35551aed08709ca2522f",
}

func TestRenumberedMigrationBodiesAreTheUpstreamBytes(t *testing.T) {
	t.Parallel()

	dir, err := migrations.ResolveDir()
	if err != nil {
		t.Fatal(err)
	}
	stems := migrationStems(t)
	for stem, want := range renumberedUpstreamBodySHA256 {
		raw, err := os.ReadFile(filepath.Join(dir, stem+".up.sql"))
		if err != nil {
			t.Errorf("%s: %v", stem, err)
			continue
		}
		sum := sha256.Sum256(raw)
		if got := hex.EncodeToString(sum[:]); got != want {
			t.Errorf("%s.up.sql changed: sha256 %s, want %s. Renumbering moves the numeric prefix only; re-record the digest deliberately after reviewing the new body", stem, got, want)
		}
		// The listed stem must be the one that ships at that number, so a stale
		// entry cannot keep describing a file some later rename replaced.
		number := 0
		for _, digit := range stem[:3] {
			number = number*10 + int(digit-'0')
		}
		if got := stems[number]; got != stem {
			t.Errorf("the digest table lists %s, but %d ships %q", stem, number, got)
		}
	}
	// And every shipped file in the block must be listed: an unlisted file is
	// one whose bytes no review recorded.
	for number := latestUpstreamNumber + latestUpstreamShift + 1; number <= latestForkHead; number++ {
		stem, ok := stems[number]
		if !ok {
			continue
		}
		if _, listed := renumberedUpstreamBodySHA256[stem]; !listed {
			t.Errorf("%s has no recorded body digest", stem)
		}
	}
}
