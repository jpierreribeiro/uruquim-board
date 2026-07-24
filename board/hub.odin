package board

// WP107 — the notification hub.
//
// SSE delivers server push, but the framework's stream is a per-request token
// opened in one handler and sent to LATER, from any thread (web/stream.odin,
// crystals web/sse). To fan a task change out to every browser watching a board,
// the application owns a small synchronized registry: subscribers register their
// open stream here; a mutation handler publishes an event and the hub sends it to
// the project's subscribers.
//
// CONCURRENCY. Publishers run on handler lanes (whichever request caused the
// change); subscribers register on their own lanes. The hub is guarded by a
// mutex. It is HEAP-allocated and held by pointer in App_State, because a
// sync.Mutex must never be copied and application_init returns App_State by value
// — the pointer is copied, the mutex is not.
//
// DISCONNECT. The framework gives no client-disconnect callback: the hub learns a
// subscriber is gone only when a send returns Closed, and prunes it then
// (friction F8-5). An idle subscriber that never receives an event is not pruned
// until shutdown; a heartbeat thread would fix that and is a recorded follow-up.
//
// LIFETIME. Nothing here touches the database or holds a pooled connection: a
// stream is long-lived and must not pin a connection. Notifications say WHAT
// changed; the client refetches through the ordinary authorized routes.

import "core:fmt"
import "core:sync"
import sse "crystals:web/sse"
import web "uruquim:web"

Subscriber :: struct {
	project_id: i64,
	account_id: i64,
	stream:     web.Stream,
}

Hub :: struct {
	mu:      sync.Mutex,
	subs:    [dynamic]Subscriber,
	next_id: u64, // monotonic event-id source; the client echoes it as Last-Event-ID
}

hub_new :: proc() -> ^Hub {
	h := new(Hub)
	h.subs = make([dynamic]Subscriber)
	return h
}

hub_destroy :: proc(h: ^Hub) {
	if h == nil {
		return
	}
	sync.mutex_lock(&h.mu)
	for &sub in h.subs {
		web.stream_close(sub.stream)
	}
	delete(h.subs)
	sync.mutex_unlock(&h.mu)
	free(h)
}

// hub_subscribe registers an open stream for a project. The caller has already
// authorized the account for the project and opened the SSE stream.
hub_subscribe :: proc(h: ^Hub, project_id: i64, account_id: i64, s: web.Stream) {
	sync.mutex_lock(&h.mu)
	defer sync.mutex_unlock(&h.mu)
	append(&h.subs, Subscriber{project_id = project_id, account_id = account_id, stream = s})
}

// hub_publish sends one event to every subscriber of `project_id`, and prunes any
// subscriber whose stream reports Closed (the client left). It stamps a
// monotonic id so a reconnecting client can carry a Last-Event-ID cursor. The
// send is non-blocking; a subscriber whose bounded queue is Full keeps its slot
// (the next event, or a heartbeat, will find it gone if it truly left).
hub_publish :: proc(h: ^Hub, project_id: i64, event: string, data: string) {
	sync.mutex_lock(&h.mu)
	defer sync.mutex_unlock(&h.mu)

	h.next_id += 1
	ev := sse.Event {
		event = event,
		id    = fmt.tprintf("%d", h.next_id),
		data  = data,
	}

	// Compact in place: keep every non-matching subscriber, and every matching
	// subscriber whose stream is still live; drop matching-and-Closed.
	write := 0
	for i in 0 ..< len(h.subs) {
		sub := h.subs[i]
		keep := true
		if sub.project_id == project_id {
			if sse.send(sub.stream, ev) == .Closed {
				keep = false
			}
		}
		if keep {
			h.subs[write] = sub
			write += 1
		}
	}
	resize(&h.subs, write)
}

// notify is the mutation handlers' entry point: publish "what changed" to a
// project's subscribers. The payload is a tiny JSON object built from a CLOSED
// vocabulary (kind + id), never user free-text, so it carries no injection.
notify :: proc(h: ^Hub, project_id: i64, event: string, kind: string, target_id: i64) {
	hub_publish(h, project_id, event, fmt.tprintf(`{{"kind":"%s","id":%d}}`, kind, target_id))
}

// hub_resync tells a single reconnecting stream to refetch. A dropped client
// reconnects with a Last-Event-ID; rather than replay an event log the board does
// not keep, the notification model (say WHAT changed, client refetches) collapses
// a reconnect to one "resync" nudge — the client reloads through the authorized
// routes and is consistent again.
hub_resync :: proc(s: web.Stream) {
	sse.send(s, sse.Event{event = "resync", data = "refetch", retry = 3000})
}
