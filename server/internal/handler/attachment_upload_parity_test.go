package handler

import (
	"bytes"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/google/uuid"

	"github.com/multica-ai/multica/server/internal/entitlement"
	"github.com/multica-ai/multica/server/internal/testutil"
)

// The fork's direct-upload path and upstream's multipart path are two ways to
// add the same bytes to the same workspace, so they have to make the SAME
// decisions: which uploads a storage limit admits, what a guest is told and
// allowed to bind, and what happens on a repeated completion.
//
// Every case below therefore runs BOTH paths and asserts on a shared
// expectation, rather than asserting each path separately. A test per path
// would let them drift while both stayed green — which is exactly what happened:
// the direct path shipped with no storage-limit check at all, so an `enforce`
// workspace refused a 200-byte multipart upload while accepting an unlimited
// direct one.
//
// The multipart path is `UploadFile` (server/internal/handler/file.go); the
// direct path is presign → PUT to the store → complete
// (attachment_upload.go). Both are driven through their real handlers.

// uploadPath is one of the two ways to store an attachment, reduced to the two
// operations the shared expectations need.
type uploadPath struct {
	name string
	// upload stores size bytes and returns the HTTP status plus the decoded
	// body. A non-2xx means the upload was refused.
	upload func(t *testing.T, workspaceID, userID, filename string, size int) (int, map[string]any)
}

// multipartPath is the upstream path: one request carrying the bytes.
func multipartPath() uploadPath {
	return uploadPath{
		name: "multipart",
		upload: func(t *testing.T, workspaceID, userID, filename string, size int) (int, map[string]any) {
			t.Helper()
			var body bytes.Buffer
			writer := multipart.NewWriter(&body)
			part, err := writer.CreateFormFile("file", filename)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := part.Write(bytes.Repeat([]byte("x"), size)); err != nil {
				t.Fatal(err)
			}
			if err := writer.Close(); err != nil {
				t.Fatal(err)
			}
			req := httptest.NewRequest(http.MethodPost, "/api/upload-file", &body)
			req.Header.Set("Content-Type", writer.FormDataContentType())
			req.Header.Set("X-User-ID", userID)
			req.Header.Set("X-Workspace-ID", workspaceID)
			rec := httptest.NewRecorder()
			testHandler.UploadFile(rec, req)
			return rec.Code, decodeJSONBody(rec)
		},
	}
}

// directPath is the fork's path: presign, PUT to the store, complete. It reuses
// the fake upload-capable backend the existing direct-upload tests use, so the
// store's own HEAD is what complete measures — the same authority the real
// object store is.
func directPath(t *testing.T) uploadPath {
	t.Helper()
	store := installDirectUploadStorage(t)
	return uploadPath{
		name: "direct",
		upload: func(t *testing.T, workspaceID, userID, filename string, size int) (int, map[string]any) {
			t.Helper()
			payload := bytes.Repeat([]byte("x"), size)

			body, err := json.Marshal(presignUploadRequest{
				Filename:    filename,
				ContentType: "application/octet-stream",
				SizeBytes:   int64(size),
			})
			if err != nil {
				t.Fatal(err)
			}
			req := httptest.NewRequest(http.MethodPost, "/api/attachments/presign-upload", bytes.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("X-User-ID", userID)
			req.Header.Set("X-Workspace-ID", workspaceID)
			rec := httptest.NewRecorder()
			testHandler.PresignAttachmentUpload(rec, req)
			if rec.Code != http.StatusOK {
				return rec.Code, decodeJSONBody(rec)
			}
			var presigned presignUploadResponse
			if err := json.Unmarshal(rec.Body.Bytes(), &presigned); err != nil {
				t.Fatal(err)
			}

			// The client's PUT. In the fake store this is a direct write of the
			// bytes the client chose — deliberately NOT the declared size, so a
			// declared-size check at presign cannot stand in for the real one at
			// complete.
			session := testHandler.Queries
			_ = session
			stagingKey := uploadStagingKeyForTest(t, presigned.AttachmentID)
			store.putStagingObject(stagingKey, payload, "application/octet-stream")

			return completeUploadCode(t, presigned.AttachmentID, userID, workspaceID)
		},
	}
}

func decodeJSONBody(rec *httptest.ResponseRecorder) map[string]any {
	out := map[string]any{}
	if rec.Body.Len() == 0 {
		return out
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		// A non-JSON body is still a legitimate refusal; keep the text so a
		// failing assertion can show what the handler actually wrote.
		out["_raw"] = rec.Body.String()
	}
	return out
}

// uploadStagingKeyForTest resolves the staging key the presign step recorded for
// a session, so the simulated PUT lands where complete will look.
func uploadStagingKeyForTest(t *testing.T, attachmentID string) string {
	t.Helper()
	var key string
	if err := testPool.QueryRow(t.Context(),
		`SELECT staging_key FROM attachment_upload_session WHERE id = $1`,
		attachmentID).Scan(&key); err != nil {
		t.Fatalf("read staging key for %s: %v", attachmentID, err)
	}
	return key
}

// completeUploadCode calls complete-upload and returns its status and body,
// including the error code the client branches on.
func completeUploadCode(t *testing.T, attachmentID, userID, workspaceID string) (int, map[string]any) {
	t.Helper()
	rec := completeUpload(t, attachmentID, userID, workspaceID)
	return rec.Code, decodeJSONBody(rec)
}

// storageLimitWorkspaceWithRole makes a workspace of its own whose attachments
// already hold usedBytes, plus a fresh user in the given role. A guest is a real
// member row with the guest role, which is what isGuest reads.
func storageLimitWorkspaceWithRole(t *testing.T, usedBytes int64, role string) (workspaceID, userID string) {
	t.Helper()
	workspaceID = memberLimitWorkspace(t, 0)
	dbfx.Cleanup(t, `DELETE FROM attachment WHERE workspace_id = $1`, workspaceID)
	dbfx.Cleanup(t, `DELETE FROM issue WHERE workspace_id = $1`, workspaceID)
	dbfx.Insert(t, "attachment", testutil.Cols{
		"workspace_id": workspaceID, "uploader_type": "member", "uploader_id": testUserID,
		"filename": "existing.bin", "url": "https://cdn.example.com/workspaces/" + workspaceID + "/existing.bin",
		"content_type": "application/octet-stream", "size_bytes": usedBytes,
	})
	if role == "member" {
		return workspaceID, testUserID
	}
	suffix := uuid.NewString()[:8]
	userID = dbfx.User(t, "Limit "+role+" "+suffix, "limit-"+role+"-"+suffix+"@multica.ai")
	dbfx.Member(t, workspaceID, userID, role)
	return workspaceID, userID
}

// guestWithProjectWorkspace is storageLimitWorkspaceWithRole for the cases where
// the guest has to reach an ISSUE. A guest is kept from objects outside any
// project (requireProjectVisible), so the issue has to sit in a project the
// guest was granted; otherwise the handler refuses on visibility before it ever
// reaches the binding rule under test, and the test would pass for the wrong
// reason.
func guestWithProjectWorkspace(t *testing.T, usedBytes int64) (workspaceID, guestID, issueID string) {
	t.Helper()
	workspaceID = dbfx.Workspace(t, "Parity guest "+uuid.NewString()[:8], "parity-guest-"+uuid.NewString()[:8])
	dbfx.Member(t, workspaceID, testUserID, "owner")
	project := dbfx.Project(t, "Parity guest project", testutil.Cols{"workspace_id": workspaceID})
	guestID = dbfx.User(t, "Parity guest "+uuid.NewString()[:8], "parity-guest-"+uuid.NewString()[:8]+"@multica.ai")
	dbfx.Member(t, workspaceID, guestID, "guest")
	// A guest sees only projects it is a MEMBER of (ListHiddenProjectIDsForGuest),
	// so the grant is a project_member row, not a column on member.
	dbfx.InsertNoID(t, "project_member", testutil.Cols{
		"workspace_id": workspaceID,
		"project_id":   project,
		"user_id":      guestID,
		"added_by":     testUserID,
	}, "project_id = $1 AND user_id = $2", project, guestID)
	issueID = dbfx.Issue(t, "Parity guest issue", testutil.Cols{
		"description":  "guest binding under test",
		"workspace_id": workspaceID,
		"project_id":   project,
	})
	if usedBytes > 0 {
		dbfx.Insert(t, "attachment", testutil.Cols{
			"workspace_id": workspaceID, "uploader_type": "member", "uploader_id": testUserID,
			"filename": "existing.bin", "url": "https://cdn.example.com/workspaces/" + workspaceID + "/existing.bin",
			"content_type": "application/octet-stream", "size_bytes": usedBytes,
		})
	}
	return workspaceID, guestID, issueID
}

// TestBothUploadPathsMakeTheSameStorageDecision is the case that would have
// caught the missing check: an `enforce` workspace is already at its limit, so
// BOTH paths must refuse, with the same status and the same code.
func TestBothUploadPathsMakeTheSameStorageDecision(t *testing.T) {
	for _, action := range []entitlement.Action{
		entitlement.ActionOff,
		entitlement.ActionObserve,
		entitlement.ActionEnforce,
	} {
		t.Run(string(action), func(t *testing.T) {
			// 900 of 1000 used; a 200-byte upload would cross it.
			workspaceID, userID := storageLimitWorkspaceWithRole(t, 900, "member")
			useStorageLimit(t, workspaceID, action, 1000)
			useMockStorage(t)

			direct := directPath(t)
			for _, path := range []uploadPath{multipartPath(), direct} {
				status, body := path.upload(t, workspaceID, userID, "over.png", 200)

				wantRefused := action == entitlement.ActionEnforce
				refused := status >= 400
				if refused != wantRefused {
					t.Fatalf("%s path under %s: status %d (body %v), want refused=%t",
						path.name, action, status, body, wantRefused)
				}
				if wantRefused {
					if body["code"] != storageLimitReachedCode {
						t.Fatalf("%s path refused with %v, want code %s", path.name, body, storageLimitReachedCode)
					}
					if status != http.StatusForbidden {
						t.Fatalf("%s path refused with status %d, want 403 like the multipart path",
							path.name, status)
					}
				}
			}
		})
	}
}

// A refusal must publish nothing on either path. The multipart path refuses
// before writing the object; the direct path has already stored the object by
// the time it can know the size, so what it must not do is create the
// attachment ROW. An enforce refusal therefore leaves the workspace's used bytes
// exactly where they were.
func TestRefusedUploadStoresNoAttachmentOnEitherPath(t *testing.T) {
	for _, pathName := range []string{"multipart", "direct"} {
		t.Run(pathName, func(t *testing.T) {
			workspaceID, userID := storageLimitWorkspaceWithRole(t, 900, "member")
			useStorageLimit(t, workspaceID, entitlement.ActionEnforce, 1000)
			useMockStorage(t)

			path := multipartPath()
			if pathName == "direct" {
				path = directPath(t)
			}
			status, body := path.upload(t, workspaceID, userID, "over.png", 200)
			if status < 400 {
				t.Fatalf("%s path accepted an over-limit upload: %d %v", pathName, status, body)
			}

			var rows int
			if err := testPool.QueryRow(t.Context(),
				`SELECT count(*) FROM attachment WHERE workspace_id = $1 AND filename = 'over.png'`,
				workspaceID).Scan(&rows); err != nil {
				t.Fatal(err)
			}
			if rows != 0 {
				t.Fatalf("%s path left %d attachment row(s) for a refused upload", pathName, rows)
			}

			// And the usage the next upload is measured against is unchanged.
			var used int64
			if err := testPool.QueryRow(t.Context(),
				`SELECT COALESCE(SUM(size_bytes), 0) FROM attachment WHERE workspace_id = $1`,
				workspaceID).Scan(&used); err != nil {
				t.Fatal(err)
			}
			if used != 900 {
				t.Fatalf("%s path changed used bytes to %d, want 900", pathName, used)
			}
		})
	}
}

// An observe workspace admits on both paths and records the attempt, so billing
// sees the same picture whichever way the bytes arrived.
func TestObserveActionAdmitsOnBothPathsAndRecordsTheAttempt(t *testing.T) {
	for _, pathName := range []string{"multipart", "direct"} {
		t.Run(pathName, func(t *testing.T) {
			workspaceID, userID := storageLimitWorkspaceWithRole(t, 900, "member")
			useStorageLimit(t, workspaceID, entitlement.ActionObserve, 1000)
			if pathName == "multipart" {
				useMockStorage(t)
			}

			path := multipartPath()
			if pathName == "direct" {
				path = directPath(t)
			}
			status, body := path.upload(t, workspaceID, userID, "over.png", 200)
			if status >= 400 {
				t.Fatalf("%s path refused under observe: %d %v", pathName, status, body)
			}

			overage := storageOverageOf(t, workspaceID)
			if overage.observed < 1 && overage.enforced < 1 {
				t.Fatalf("%s path recorded no over-limit attempt: %+v", pathName, overage)
			}
		})
	}
}

// A guest cannot read the workspace's storage usage, so a refusal must tell it
// the code and nothing else — on BOTH paths. The multipart path got this right
// from the start (it reads the role with the membership); the direct path had no
// refusal at all to get wrong, which is why it is asserted here.
func TestGuestRefusalCarriesNoFiguresOnEitherPath(t *testing.T) {
	for _, pathName := range []string{"multipart", "direct"} {
		t.Run(pathName, func(t *testing.T) {
			workspaceID, guestID := storageLimitWorkspaceWithRole(t, 900, "guest")
			useStorageLimit(t, workspaceID, entitlement.ActionEnforce, 1000)
			useMockStorage(t)

			path := multipartPath()
			if pathName == "direct" {
				path = directPath(t)
			}
			status, body := path.upload(t, workspaceID, guestID, "guest.png", 200)
			if status != http.StatusForbidden {
				t.Fatalf("%s path: guest got %d %v, want 403", pathName, status, body)
			}
			if body["code"] != storageLimitReachedCode {
				t.Fatalf("%s path: guest body %v, want code %s", pathName, body, storageLimitReachedCode)
			}
			for _, field := range []string{"used_bytes", "limit_bytes"} {
				if _, ok := body[field]; ok {
					t.Fatalf("%s path: guest refusal leaks %s: %v", pathName, field, body)
				}
			}
		})
	}
}

// A member DOES see the figures, on both paths — the refusal is actionable, not
// just a code.
func TestMemberRefusalCarriesTheFiguresOnBothPaths(t *testing.T) {
	for _, pathName := range []string{"multipart", "direct"} {
		t.Run(pathName, func(t *testing.T) {
			workspaceID, userID := storageLimitWorkspaceWithRole(t, 900, "member")
			useStorageLimit(t, workspaceID, entitlement.ActionEnforce, 1000)
			useMockStorage(t)

			path := multipartPath()
			if pathName == "direct" {
				path = directPath(t)
			}
			status, body := path.upload(t, workspaceID, userID, "over.png", 200)
			if status != http.StatusForbidden {
				t.Fatalf("%s path: %d %v, want 403", pathName, status, body)
			}
			if _, ok := body["used_bytes"]; !ok {
				t.Fatalf("%s path: member refusal has no used_bytes: %v", pathName, body)
			}
			if _, ok := body["limit_bytes"]; !ok {
				t.Fatalf("%s path: member refusal has no limit_bytes: %v", pathName, body)
			}
		})
	}
}

// The guests' draft rule (MUL-9420): an issue-scoped upload from a guest stays
// UNBOUND so it is a draft for its next comment, while a member's binds at once.
// Asserted for the direct path through the session row the presign step writes,
// because that row is what complete turns into the attachment.
func TestGuestIssueUploadStaysUnboundOnTheDirectPath(t *testing.T) {
	workspaceID, guestID, issueID := guestWithProjectWorkspace(t, 0)
	store := installDirectUploadStorage(t)

	body, err := json.Marshal(presignUploadRequest{
		Filename:    "draft.png",
		ContentType: "image/png",
		SizeBytes:   5,
		IssueID:     issueID,
	})
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/api/attachments/presign-upload", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-User-ID", guestID)
	req.Header.Set("X-Workspace-ID", workspaceID)
	rec := httptest.NewRecorder()
	testHandler.PresignAttachmentUpload(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("guest presign = %d: %s", rec.Code, rec.Body.String())
	}
	var presigned presignUploadResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &presigned); err != nil {
		t.Fatal(err)
	}

	var boundIssue *string
	if err := testPool.QueryRow(t.Context(),
		`SELECT issue_id::text FROM attachment_upload_session WHERE id = $1`,
		presigned.AttachmentID).Scan(&boundIssue); err != nil {
		t.Fatal(err)
	}
	if boundIssue != nil {
		t.Fatalf("guest's issue upload bound issue_id=%s; it must stay a draft until the comment links it",
			*boundIssue)
	}

	// Positive control: a member's identical upload does bind, so the rule above
	// is "guests are exempt", not "issue binding is broken".
	memberBody, err := json.Marshal(presignUploadRequest{
		Filename:    "member.png",
		ContentType: "image/png",
		SizeBytes:   5,
		IssueID:     issueID,
	})
	if err != nil {
		t.Fatal(err)
	}
	memberReq := httptest.NewRequest(http.MethodPost, "/api/attachments/presign-upload", bytes.NewReader(memberBody))
	memberReq.Header.Set("Content-Type", "application/json")
	memberReq.Header.Set("X-User-ID", testUserID)
	memberReq.Header.Set("X-Workspace-ID", workspaceID)
	memberRec := httptest.NewRecorder()
	testHandler.PresignAttachmentUpload(memberRec, memberReq)
	if memberRec.Code != http.StatusOK {
		t.Fatalf("member presign = %d: %s", memberRec.Code, memberRec.Body.String())
	}
	var memberPresigned presignUploadResponse
	if err := json.Unmarshal(memberRec.Body.Bytes(), &memberPresigned); err != nil {
		t.Fatal(err)
	}
	var memberBound *string
	if err := testPool.QueryRow(t.Context(),
		`SELECT issue_id::text FROM attachment_upload_session WHERE id = $1`,
		memberPresigned.AttachmentID).Scan(&memberBound); err != nil {
		t.Fatal(err)
	}
	if memberBound == nil {
		t.Fatal("member's issue upload stayed unbound; it must bind at once")
	}
	_ = store
}

// A guest may attach only to its own comment. The direct path must refuse
// another person's comment before any credential is issued, exactly as the
// multipart path does.
func TestGuestCannotPresignAgainstAnotherPersonsComment(t *testing.T) {
	workspaceID, guestID, issueID := guestWithProjectWorkspace(t, 0)
	// A comment authored by the test MEMBER, not the guest.
	commentID := dbfx.Comment(t, issueID, "owned by the member", testutil.Cols{
		"workspace_id": workspaceID,
		"author_type":  "member",
		"author_id":    testUserID,
	})

	installDirectUploadStorage(t)

	body, err := json.Marshal(presignUploadRequest{
		Filename:    "hijack.png",
		ContentType: "image/png",
		SizeBytes:   5,
		CommentID:   commentID,
	})
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/api/attachments/presign-upload", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-User-ID", guestID)
	req.Header.Set("X-Workspace-ID", workspaceID)
	rec := httptest.NewRecorder()
	testHandler.PresignAttachmentUpload(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("guest presign against a member's comment = %d %s, want 403",
			rec.Code, rec.Body.String())
	}
	if body := decodeJSONBody(rec); body["error"] != "invalid comment_id" {
		t.Fatalf("refusal body = %v, want invalid comment_id", body)
	}

	// Positive control: the member may attach to its own comment.
	memberBody, err := json.Marshal(presignUploadRequest{
		Filename:    "own.png",
		ContentType: "image/png",
		SizeBytes:   5,
		CommentID:   commentID,
	})
	if err != nil {
		t.Fatal(err)
	}
	memberReq := httptest.NewRequest(http.MethodPost, "/api/attachments/presign-upload", bytes.NewReader(memberBody))
	memberReq.Header.Set("Content-Type", "application/json")
	memberReq.Header.Set("X-User-ID", testUserID)
	memberReq.Header.Set("X-Workspace-ID", workspaceID)
	memberRec := httptest.NewRecorder()
	testHandler.PresignAttachmentUpload(memberRec, memberReq)
	if memberRec.Code != http.StatusOK {
		t.Fatalf("member presign against its own comment = %d %s, want 200",
			memberRec.Code, memberRec.Body.String())
	}
}

// Repeated completion must publish ONE attachment and return the same row, which
// is the fork's documented idempotency contract. A retry is the normal case (a
// lost response), so this is asserted rather than assumed.
func TestRepeatedCompletePublishesOneAttachment(t *testing.T) {
	workspaceID, userID := storageLimitWorkspaceWithRole(t, 0, "member")
	store := installDirectUploadStorage(t)

	body, err := json.Marshal(presignUploadRequest{
		Filename:    "once.png",
		ContentType: "image/png",
		SizeBytes:   8,
	})
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/api/attachments/presign-upload", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-User-ID", userID)
	req.Header.Set("X-Workspace-ID", workspaceID)
	rec := httptest.NewRecorder()
	testHandler.PresignAttachmentUpload(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("presign = %d: %s", rec.Code, rec.Body.String())
	}
	var presigned presignUploadResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &presigned); err != nil {
		t.Fatal(err)
	}
	store.putStagingObject(uploadStagingKeyForTest(t, presigned.AttachmentID),
		bytes.Repeat([]byte("x"), 8), "image/png")

	var firstID string
	for attempt := 1; attempt <= 3; attempt++ {
		status, body := completeUploadCode(t, presigned.AttachmentID, userID, workspaceID)
		if status >= 400 {
			t.Fatalf("complete attempt %d = %d %v, want success", attempt, status, body)
		}
		id, _ := body["id"].(string)
		if id == "" {
			t.Fatalf("complete attempt %d returned no attachment id: %v", attempt, body)
		}
		if attempt == 1 {
			firstID = id
		} else if id != firstID {
			t.Fatalf("complete attempt %d published a different attachment %s, want %s",
				attempt, id, firstID)
		}
	}

	var rows int
	if err := testPool.QueryRow(t.Context(),
		`SELECT count(*) FROM attachment WHERE workspace_id = $1 AND filename = 'once.png'`,
		workspaceID).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 1 {
		t.Fatalf("repeated complete created %d attachment rows, want 1", rows)
	}
}

// Concurrent completion is the same contract under a race: the session lock is
// what makes it hold, so it is worth asserting rather than reasoning about.
func TestConcurrentCompletePublishesOneAttachment(t *testing.T) {
	workspaceID, userID := storageLimitWorkspaceWithRole(t, 0, "member")
	store := installDirectUploadStorage(t)

	body, err := json.Marshal(presignUploadRequest{
		Filename:    "race.png",
		ContentType: "image/png",
		SizeBytes:   8,
	})
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/api/attachments/presign-upload", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-User-ID", userID)
	req.Header.Set("X-Workspace-ID", workspaceID)
	rec := httptest.NewRecorder()
	testHandler.PresignAttachmentUpload(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("presign = %d: %s", rec.Code, rec.Body.String())
	}
	var presigned presignUploadResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &presigned); err != nil {
		t.Fatal(err)
	}
	store.putStagingObject(uploadStagingKeyForTest(t, presigned.AttachmentID),
		bytes.Repeat([]byte("x"), 8), "image/png")

	const racers = 4
	type result struct {
		status int
		id     string
	}
	results := make(chan result, racers)
	start := make(chan struct{})
	for i := 0; i < racers; i++ {
		go func() {
			<-start
			status, body := completeUploadCode(t, presigned.AttachmentID, userID, workspaceID)
			id, _ := body["id"].(string)
			results <- result{status: status, id: id}
		}()
	}
	close(start)

	seen := map[string]bool{}
	for i := 0; i < racers; i++ {
		r := <-results
		if r.status >= 400 {
			t.Fatalf("concurrent complete returned %d", r.status)
		}
		if r.id == "" {
			t.Fatalf("concurrent complete returned no attachment id")
		}
		seen[r.id] = true
	}
	if len(seen) != 1 {
		t.Fatalf("concurrent completes returned %d distinct attachment ids %v, want 1", len(seen), seen)
	}

	var rows int
	if err := testPool.QueryRow(t.Context(),
		`SELECT count(*) FROM attachment WHERE workspace_id = $1 AND filename = 'race.png'`,
		workspaceID).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 1 {
		t.Fatalf("concurrent complete created %d attachment rows, want 1", rows)
	}
}

// A refusal must not depend on which path is used when the OBJECT is inconsistent
// either: if the stored bytes do not match the declared size, both paths refuse.
// This is the direct path's own contract (the store is the authority), and the
// case below is the one a declared-size check at presign cannot cover.
func TestDirectPathRefusesAnObjectOfTheWrongSize(t *testing.T) {
	workspaceID, userID := storageLimitWorkspaceWithRole(t, 0, "member")
	store := installDirectUploadStorage(t)

	body, err := json.Marshal(presignUploadRequest{
		Filename:    "short.png",
		ContentType: "image/png",
		SizeBytes:   100,
	})
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/api/attachments/presign-upload", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-User-ID", userID)
	req.Header.Set("X-Workspace-ID", workspaceID)
	rec := httptest.NewRecorder()
	testHandler.PresignAttachmentUpload(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("presign = %d: %s", rec.Code, rec.Body.String())
	}
	var presigned presignUploadResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &presigned); err != nil {
		t.Fatal(err)
	}
	// 3 bytes stored against 100 declared.
	store.putStagingObject(uploadStagingKeyForTest(t, presigned.AttachmentID),
		[]byte("abc"), "image/png")

	status, refusal := completeUploadCode(t, presigned.AttachmentID, userID, workspaceID)
	if status != http.StatusConflict {
		t.Fatalf("complete with a 3-byte object = %d %v, want 409", status, refusal)
	}
	if refusal["code"] != codeUploadSizeMismatch {
		t.Fatalf("refusal code = %v, want %s", refusal["code"], codeUploadSizeMismatch)
	}
}

// The refusal must be reachable through the same code path a real client uses,
// so the case above is not defeated by a handler that was tested in isolation
// with the limit unset. This asserts a workspace with no entitlement configured
// (the self-hosted default) admits on both paths: the check must not refuse when
// there is no limit.
func TestNoConfiguredLimitAdmitsOnBothPaths(t *testing.T) {
	workspaceID, userID := storageLimitWorkspaceWithRole(t, 900, "member")
	// No useStorageLimit: h.Entitlements stays nil, which is the self-hosted
	// default and means "off, read nothing".
	useMockStorage(t)

	direct := directPath(t)
	for _, path := range []uploadPath{multipartPath(), direct} {
		status, body := path.upload(t, workspaceID, userID, "free.png", 200)
		if status >= 400 {
			t.Fatalf("%s path refused with no limit configured: %d %v", path.name, status, body)
		}
	}
}

// --- publish-time revalidation of role and binding -------------------------
//
// The presign gate decides what a session may be bound to, but a session can
// outlive the decision: presign and complete are separated by the client's PUT,
// which can take minutes for a large file. The publish transaction therefore has
// to re-apply the role-dependent rules, not just re-check that the targets still
// exist. These tests demote or revoke BETWEEN presign and complete, which is the
// only way to reach that window.

// presignSession issues a session for the given target and returns its id, so a
// test can mutate the world before completing it.
func presignSessionID(t *testing.T, userID, workspaceID string, req presignUploadRequest) string {
	t.Helper()
	body, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest(http.MethodPost, "/api/attachments/presign-upload", bytes.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("X-User-ID", userID)
	r.Header.Set("X-Workspace-ID", workspaceID)
	rec := httptest.NewRecorder()
	testHandler.PresignAttachmentUpload(rec, r)
	if rec.Code != http.StatusOK {
		t.Fatalf("presign = %d: %s", rec.Code, rec.Body.String())
	}
	var out presignUploadResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	return out.AttachmentID
}

// A member whose issue-scoped session was created before they were demoted to
// guest must not publish it against the issue: every issue reader would see a
// draft its author had not posted.
func TestDemotedMemberCannotPublishIssueDraft(t *testing.T) {
	workspaceID, guestID, issueID := guestWithProjectWorkspace(t, 0)
	store := installDirectUploadStorage(t)

	// The caller is a MEMBER at presign time, so the session binds to the issue.
	dbfx.Exec(t, `UPDATE member SET role = 'member' WHERE workspace_id = $1 AND user_id = $2`,
		workspaceID, guestID)

	sessionID := presignSessionID(t, guestID, workspaceID, presignUploadRequest{
		Filename:    "draft.png",
		ContentType: "image/png",
		SizeBytes:   5,
		IssueID:     issueID,
	})
	store.putStagingObject(uploadStagingKeyForTest(t, sessionID), []byte("hello"), "image/png")

	// Demote between presign and complete.
	dbfx.Exec(t, `UPDATE member SET role = 'guest' WHERE workspace_id = $1 AND user_id = $2`,
		workspaceID, guestID)

	status, body := completeUploadCode(t, sessionID, guestID, workspaceID)
	if status != http.StatusForbidden {
		t.Fatalf("complete after demotion = %d %v, want 403", status, body)
	}
	if body["code"] != codeUploadTargetInvalid {
		t.Fatalf("refusal code = %v, want %s", body["code"], codeUploadTargetInvalid)
	}
	var rows int
	if err := testPool.QueryRow(t.Context(),
		`SELECT count(*) FROM attachment WHERE workspace_id = $1 AND filename = 'draft.png'`,
		workspaceID).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 0 {
		t.Fatalf("a refused post-demotion publish created %d attachment row(s)", rows)
	}
}

// The same window for a comment: a member demoted to guest must not publish onto
// somebody else's comment.
func TestDemotedMemberCannotPublishToForeignComment(t *testing.T) {
	workspaceID, userID, issueID := guestWithProjectWorkspace(t, 0)
	store := installDirectUploadStorage(t)
	commentID := dbfx.Comment(t, issueID, "someone else's comment", testutil.Cols{
		"workspace_id": workspaceID,
		"author_type":  "member",
		"author_id":    testUserID,
	})

	dbfx.Exec(t, `UPDATE member SET role = 'member' WHERE workspace_id = $1 AND user_id = $2`,
		workspaceID, userID)
	sessionID := presignSessionID(t, userID, workspaceID, presignUploadRequest{
		Filename:    "onto-comment.png",
		ContentType: "image/png",
		SizeBytes:   5,
		CommentID:   commentID,
	})
	store.putStagingObject(uploadStagingKeyForTest(t, sessionID), []byte("hello"), "image/png")
	dbfx.Exec(t, `UPDATE member SET role = 'guest' WHERE workspace_id = $1 AND user_id = $2`,
		workspaceID, userID)

	status, body := completeUploadCode(t, sessionID, userID, workspaceID)
	if status != http.StatusForbidden {
		t.Fatalf("complete after demotion = %d %v, want 403", status, body)
	}
}

// A member's own upload is unaffected by the new recheck: the rule must refuse
// demotion, not guests in general.
func TestMemberPublishAfterRoleCheckStillSucceeds(t *testing.T) {
	workspaceID, userID, issueID := guestWithProjectWorkspace(t, 0)
	store := installDirectUploadStorage(t)
	dbfx.Exec(t, `UPDATE member SET role = 'member' WHERE workspace_id = $1 AND user_id = $2`,
		workspaceID, userID)

	sessionID := presignSessionID(t, userID, workspaceID, presignUploadRequest{
		Filename:    "member-ok.png",
		ContentType: "image/png",
		SizeBytes:   5,
		IssueID:     issueID,
	})
	store.putStagingObject(uploadStagingKeyForTest(t, sessionID), []byte("hello"), "image/png")

	status, body := completeUploadCode(t, sessionID, userID, workspaceID)
	if status >= 400 {
		t.Fatalf("member publish = %d %v, want success", status, body)
	}
}

// Revocation between presign and complete: the member row is gone entirely, so
// the publish must be refused. This is the case the existing membership check
// covers, asserted here so the new role logic cannot weaken it.
func TestRevokedMemberCannotPublish(t *testing.T) {
	workspaceID, userID, issueID := guestWithProjectWorkspace(t, 0)
	store := installDirectUploadStorage(t)
	dbfx.Exec(t, `UPDATE member SET role = 'member' WHERE workspace_id = $1 AND user_id = $2`,
		workspaceID, userID)

	sessionID := presignSessionID(t, userID, workspaceID, presignUploadRequest{
		Filename:    "revoked.png",
		ContentType: "image/png",
		SizeBytes:   5,
		IssueID:     issueID,
	})
	store.putStagingObject(uploadStagingKeyForTest(t, sessionID), []byte("hello"), "image/png")

	dbfx.Exec(t, `DELETE FROM member WHERE workspace_id = $1 AND user_id = $2`, workspaceID, userID)

	status, body := completeUploadCode(t, sessionID, userID, workspaceID)
	if status != http.StatusForbidden {
		t.Fatalf("complete after revocation = %d %v, want 403", status, body)
	}
	var rows int
	if err := testPool.QueryRow(t.Context(),
		`SELECT count(*) FROM attachment WHERE workspace_id = $1 AND filename = 'revoked.png'`,
		workspaceID).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 0 {
		t.Fatalf("a refused post-revocation publish created %d attachment row(s)", rows)
	}
}

// Replay idempotency: a repeat completion of an ALREADY PUBLISHED session returns
// the same attachment rather than re-running the policy gates. A retry after a
// lost response is the normal case, and it must not start failing because the
// caller's role changed after the first success — the attachment exists, and
// returning it is the documented contract.
func TestReplayAfterSuccessReturnsSameAttachmentDespiteLaterDemotion(t *testing.T) {
	workspaceID, userID, issueID := guestWithProjectWorkspace(t, 0)
	store := installDirectUploadStorage(t)
	dbfx.Exec(t, `UPDATE member SET role = 'member' WHERE workspace_id = $1 AND user_id = $2`,
		workspaceID, userID)

	sessionID := presignSessionID(t, userID, workspaceID, presignUploadRequest{
		Filename:    "replay.png",
		ContentType: "image/png",
		SizeBytes:   5,
		IssueID:     issueID,
	})
	store.putStagingObject(uploadStagingKeyForTest(t, sessionID), []byte("hello"), "image/png")

	status, first := completeUploadCode(t, sessionID, userID, workspaceID)
	if status >= 400 {
		t.Fatalf("first complete = %d %v", status, first)
	}
	firstID, _ := first["id"].(string)

	// Demote after the attachment exists; the replay must still resolve it.
	dbfx.Exec(t, `UPDATE member SET role = 'guest' WHERE workspace_id = $1 AND user_id = $2`,
		workspaceID, userID)

	status, replay := completeUploadCode(t, sessionID, userID, workspaceID)
	if status >= 400 {
		t.Fatalf("replay after demotion = %d %v, want the published attachment", status, replay)
	}
	if id, _ := replay["id"].(string); id != firstID {
		t.Fatalf("replay returned attachment %q, want %q", id, firstID)
	}
	var rows int
	if err := testPool.QueryRow(t.Context(),
		`SELECT count(*) FROM attachment WHERE workspace_id = $1 AND filename = 'replay.png'`,
		workspaceID).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 1 {
		t.Fatalf("replay produced %d attachment rows, want 1", rows)
	}
}
