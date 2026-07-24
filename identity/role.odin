package identity

// WP104 — per-project roles and their ranking.
//
// The role SET is closed (mirrored by the CHECK constraint in migration
// 0002_projects). The database stores the role as text; the application ranks
// it here. Ranking is a total order — owner > maintainer > member > viewer — so
// an authorization check is "does this member's role rank at least as high as
// the action requires" (see board/authz.odin require_role).
//
// Pure and unit-tested without a database.

Role :: enum u8 {
	Viewer     = 0,
	Member     = 1,
	Maintainer = 2,
	Owner      = 3,
}

// role_string is the canonical wire/storage spelling. It MUST match the values
// the 0002 CHECK constraint permits, or a write the app believes valid is
// rejected by the database.
role_string :: proc(r: Role) -> string {
	switch r {
	case .Owner:
		return "owner"
	case .Maintainer:
		return "maintainer"
	case .Member:
		return "member"
	case .Viewer:
		return "viewer"
	}
	return "viewer"
}

// role_parse maps a stored/received string to a Role. An unknown string is
// ok=false — never a silent default, so a corrupted column or a bad request
// cannot smuggle in an unintended privilege level.
role_parse :: proc(s: string) -> (Role, bool) {
	switch s {
	case "owner":
		return .Owner, true
	case "maintainer":
		return .Maintainer, true
	case "member":
		return .Member, true
	case "viewer":
		return .Viewer, true
	}
	return .Viewer, false
}

// role_allows reports whether a member holding `have` may perform an action that
// requires at least `need`. The enum's integer ranking is the whole check.
role_allows :: proc(have: Role, need: Role) -> bool {
	return u8(have) >= u8(need)
}
