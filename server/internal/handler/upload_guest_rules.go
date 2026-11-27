package handler

import (
	"net/http"

	db "github.com/multica-ai/multica/server/pkg/db/generated"
)

// Guest attachment rules (MUL-9420), in one place.
//
// These were duplicated between the multipart path (file.go) and the direct
// upload path (attachment_upload.go), and the direct path's copy was incomplete:
// it had neither rule, so a guest could bind an upload to the issue itself and
// could attach to somebody else's comment. Duplication is what let that happen,
// so both paths — and the publish-time revalidation — now call these.

// guestUploader reports whether this request acts as a workspace guest. It
// resolves through the cached member when the middleware already loaded one, so
// calling it on a hot path does not add a query per request.
func (h *Handler) guestUploader(r *http.Request, workspaceID, userID, actorType string) bool {
	// Only a member-role actor can be a guest: an agent actor is never one, and
	// asking would look up a member row for an agent id.
	if actorType != "member" {
		return false
	}
	return h.isGuest(r, workspaceID, userID)
}

// guestIssueBindingAllowed reports whether an upload targeting issueID should be
// BOUND to the issue.
//
// A guest's upload is a draft for its next comment, not a change to the issue, so
// it stays unbound — visible only to the guest — until CreateComment links it.
// A member's upload binds at once.
func (h *Handler) guestIssueBindingAllowed(r *http.Request, workspaceID, userID, actorType string) bool {
	return !h.guestUploader(r, workspaceID, userID, actorType)
}

// guestCommentBindingAllowed reports whether this actor may attach to the given
// comment. A guest attaches files only to its OWN comments: being able to see a
// comment is not permission to add to it.
func (h *Handler) guestCommentBindingAllowed(r *http.Request, workspaceID, userID, actorType, actorID string, comment db.Comment) bool {
	if !h.guestUploader(r, workspaceID, userID, actorType) {
		return true
	}
	return comment.AuthorType == "member" && uuidToString(comment.AuthorID) == actorID
}
