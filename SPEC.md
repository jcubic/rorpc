# RO/RPC — Remote Object / Remote Procedure Call

**Version 1.0** · Status: Draft · 2026-09-28

RO/RPC is a stateless, transport-agnostic protocol for using an object that lives somewhere
else. Where [JSON-RPC](https://www.jsonrpc.org/specification) calls one named method with
arguments, RO/RPC replays a **chain** of property reads, property writes and calls against
an object that never leaves the context that owns it — a user interface element, a parsed
document, a database cursor, a file handle: anything whose behaviour, rather than its data,
is the point of it.

A chain is a list of steps. Written out, this one is four:

```
report.section("summary").rows.first().text()
```

```json
[
  { "type": "get", "key": "section" },
  { "type": "call", "args": ["summary"] },
  { "type": "get", "key": "rows" },
  { "type": "get", "key": "first" },
  { "type": "call", "args": [] },
  { "type": "get", "key": "text" },
  { "type": "call", "args": [] }
]
```

One message, and the object stayed where it was. A protocol that called one method at a
time would need four round trips and three intermediate objects it could not send.

**A step may pass a function.** The function does not travel; a reference to it does, and
the Host calls back across the same connection while the chain is still running:

```
report.section("summary").rows.find(callback).text()
```

```json
{ "type": "call", "args": [{ "__type__": "function", "__data__": { "callback": 1 } }] }
```

`find` runs on the Host. Each time it tests a row, the Host asks the Client to run
`callback` and waits for the answer, then the chain continues and answers as one Response.
Section 11 describes this.

### A note on languages

Nothing here is specific to one language. The two ends may be written in different
languages, and the protocol carries no types beyond those JSON defines.

How a chain is _built_ does differ. A language with runtime interception — proxies in
JavaScript, `__getattr__` in Python, `method_missing` in Ruby — can record a chain from
ordinary syntax, so remote code reads like local code. A language without it builds the
same chain through an explicit API:

```
remote("report").get("section").call("summary").get("rows").call("text")
```

Both produce the message above, and a peer cannot tell which was used. Section 16 collects
the points where a language's own conventions have to be mapped onto the protocol.

## Table of contents

1. [Conventions](#1-conventions)
2. [Roles](#2-roles)
3. [Transport requirements](#3-transport-requirements)
4. [Encoding](#4-encoding)
5. [Protocol version](#5-protocol-version)
6. [Values](#6-values)
7. [Messages](#7-messages)
8. [Chain evaluation](#8-chain-evaluation)
9. [Errors](#9-errors)
10. [Handles](#10-handles)
11. [Callbacks](#11-callbacks)
12. [Ordering and concurrency](#12-ordering-and-concurrency)
13. [Security considerations](#13-security-considerations)
14. [Differences from JSON-RPC 2.0](#14-differences-from-json-rpc-20)
15. [Conformance](#15-conformance)
16. [Language mapping](#16-language-mapping)
17. [Appendix A: schema](#appendix-a-schema)
18. [Appendix B: an annotated session](#appendix-b-an-annotated-session)

- [Changelog](#changelog)

---

## Changelog

While the status is **Draft** the version stays at `1.0`. A draft is not something an
implementation can be held to yet, so a change here does not bump the version — it is
recorded below instead. The version starts to move when this document leaves Draft.

### 2026-09-28

- §6.1 Object marker: new OPTIONAL `repr` member, a Host-built string form of the object
  behind a handle. Added with §6.1.1, on why it travels with the handle rather than being
  asked for later.

### 2026-09-27

- First draft.

---

## 1. Conventions

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED,
MAY and OPTIONAL are to be interpreted as described in [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119).

"JSON value", "object", "array", "string", "number", "null" refer to the types defined by
[RFC 8259](https://www.rfc-editor.org/rfc/rfc8259).

A key described as absent MAY equivalently be present with the value `null` **only where
this document says so**. Otherwise absence and `null` are distinct.

## 2. Roles

| Role       | Holds                                  | Sends                                       |
| ---------- | -------------------------------------- | ------------------------------------------- |
| **Host**   | The real objects, and the handle table | Responses, callback invocations             |
| **Client** | Proxies, and the callback table        | Requests, callback results, release notices |

The roles are **asymmetric and fixed for the life of a connection**. A Host never issues a
Request; a Client never issues a Response. An implementation MAY run a Host and a Client
over the same connection to get a bidirectional link, but they are then two independent
RO/RPC sessions that happen to share a transport, and Section 12.3 applies.

Neither role implies a location. The Host may be a browser page and the Client a worker, or
the Host may be a server and the Client a browser; the protocol does not distinguish.

## 3. Transport requirements

A conforming transport MUST:

- **T1. Carry Unicode text.** Messages are JSON text. A transport that carries only binary
  MUST encode as UTF-8.
- **T2. Preserve order** between a single sender and a single receiver. Messages sent as
  A then B MUST arrive as A then B.
- **T3. Not deliver a message back to its sender.** A transport that echoes MUST be wrapped
  so that it does not; see Section 12.3 for why.
- **T4. Be connected to exactly one peer**, or provide addressing outside this protocol.
  RO/RPC identifiers are per-connection and are not globally unique.

A transport is NOT REQUIRED to be reliable, ordered across senders, or to signal
disconnection. RO/RPC defines no heartbeat, reconnection or delivery acknowledgement.

Examples of conforming transports: a `Worker` and its `DedicatedWorkerGlobalScope`; a
`MessagePort` pair; a WebSocket; an `RTCDataChannel`; a `BroadcastChannel` with exactly two
endpoints.

## 4. Encoding

Every message is a single JSON object, serialized as one transport message. Implementations
MUST NOT split a message across transport messages, and MUST NOT batch several messages into
one. (JSON-RPC batching is deliberately absent; see Section 14.)

A receiver that cannot parse a message as JSON MUST ignore it. It MUST NOT reply, because a
message it could not parse carries no identifier to reply to.

**An absent member means "no value".** JSON offers only `null`, and languages differ on
whether they have one empty value or two. RO/RPC therefore distinguishes three cases for an
optional member: present with a value; present as `null`; and absent. A Response with no
`result` member reports that the chain produced nothing, which is distinct from a Response
whose `result` is `null`. Section 16.1 gives the mapping for languages that do not draw
that distinction.

## 5. Protocol version

Every message MUST carry a `rorpc` member whose value is a version string:

```json
{ "rorpc": "1.0", "id": 1, "namespace": "$", "ops": [] }
```

The value MUST match `MAJOR "." MINOR`, where both parts are non-negative integers without
leading zeros. This document specifies `"1.0"`.

### 5.1 Compatibility

- Two peers are compatible when the MAJOR parts are equal.
- A MINOR increment MUST be backward compatible: it MAY add OPTIONAL members or new
  `__type__` markers, and MUST NOT change the meaning of anything specified here.
- A peer MUST ignore members it does not recognise, so that a lower-minor peer can talk to a
  higher-minor one.

### 5.2 Mismatch

A receiver that gets a message whose `rorpc` member is absent, malformed, or of a different
MAJOR version:

- MUST NOT act on it;
- MUST reply with a `-32012` error (Section 9.2) if the message classifies as a Request
  under Section 7.6;
- MUST otherwise ignore it silently.

The version is checked **after** the message has been classified, not before. Only a
would-be Request may be answered: replying to anything else would mean answering a Response
overheard on a shared transport, which is the exchange Section 7.6 exists to stop.

A Client has no error reply to send. It MAY instead fail the pending Request the message
correlates to, rather than leave a caller waiting on a peer it cannot speak to.

A peer MUST NOT attempt to negotiate downward. There is no handshake: the version travels
on every message precisely so that no round trip is needed before the first call.

> **Note.** The absent case is what distinguishes RO/RPC 1.0 from the unversioned wire
> format used by `@jcubic/mitty` up to 0.4.x. See Section 15.2.

## 6. Values

Any JSON value may appear as an argument, a `set` value, or a result. Three object shapes
are **reserved**: an object carrying both a `__type__` string and a `__data__` object is a
**marker** and MUST be interpreted as such.

```
marker = { "__type__": string, "__data__": object }
```

Members are named, so a marker reads without reference to this document, unknown members
can be added without renumbering, and an optional member is simply absent rather than
a `null` holding a place.

The dunder names are deliberate. `{ type, data }` is an ordinary shape to find in
application data; `{ __type__, __data__ }` is not. An application value of the reserved shape
cannot be transmitted; see Section 13.4.

A receiver that encounters a `__type__` it does not recognise MUST treat the object as an
ordinary JSON object (forward compatibility, Section 5.1).

### 6.1 Object marker

```json
{ "__type__": "object", "__data__": { "handle": 1 } }
{ "__type__": "object", "__data__": { "handle": 2, "repr": "#<jQuery [3]>" } }
```

| Member   | Type    | Required | Meaning                                       |
| -------- | ------- | -------- | --------------------------------------------- |
| `handle` | integer | yes      | Entry in the Host's handle table (§10)        |
| `repr`   | string  | no       | A short string form of the object; see §6.1.1 |

Direction: **both**. From Host to Client it introduces a handle. From Client to Host it
refers to one already introduced, and the Host MUST substitute the object it names before
evaluation.

#### 6.1.1 `repr`

A handle stands for an object the Client never receives, so the Client has nothing from
which to build a readable name for it. `repr` is that name, built by the Host, which does
hold the object.

- `repr` is **added by the Host when it mints the handle**, and MUST NOT be sent by the
  Client. A Client referring to a handle sends the integer alone.
- A Host MAY omit it. A Client that receives no `repr` MUST still work.
- Its content is unspecified: it is for a person to read — a log line, a REPL, an error
  message — and a Client MUST NOT parse it or treat it as identity.

It travels with the handle rather than being requested later because a Client typically
needs it where no round trip is possible. In JavaScript, `String(handle)` runs
`Symbol.toPrimitive`, which must return a value immediately and cannot await a Response.
Any language with synchronous string conversion has the same constraint.

### 6.2 Function marker

```json
{ "__type__": "function", "__data__": { "callback": 2 } }
{ "__type__": "function", "__data__": { "callback": 1, "arity": 1 } }
```

| Member     | Type    | Required | Meaning                                          |
| ---------- | ------- | -------- | ------------------------------------------------ |
| `callback` | integer | yes      | Entry in the Client's callback table (§11)       |
| `arity`    | integer | **no**   | Most arguments the Client will accept; see §11.2 |

An absent `arity` places no limit: the Host sends every argument the call produced. The
first example above asks for all of them, the second for one.

Direction: **Client to Host only**. A Host MUST NOT emit a function marker; functions in a
result are dropped, exactly as `JSON.stringify` drops them. A Host that wishes to expose a
function MUST expose it as a handle instead.

### 6.3 Error marker

```json
{
  "__type__": "error",
  "__data__": {
    "name": "TypeError",
    "message": "$.nope is not a function",
    "code": -32010
  }
}
```

| Member    | Type    | Required | Meaning                                 |
| --------- | ------- | -------- | --------------------------------------- |
| `name`    | string  | yes      | Error class name, e.g. `"TypeError"`    |
| `message` | string  | yes      | Human-readable description              |
| `stack`   | string  | no       | Stack as captured where the error arose |
| `code`    | integer | no       | Machine-readable cause; see Section 9.2 |

Direction: **both**.

A receiver MUST reconstruct an error object carrying at least `name` and `message`, and
MUST tolerate members it does not recognise.

`stack` and `code` are optional and are absent when not supplied; a receiver MUST NOT treat
an absent `stack` as an error.

Only these four members are defined. **An error's own fields do not travel.** A file error
arrives without the path it failed on, a validation error without the list of what failed.
An application that needs more MUST carry it in `message` or distinguish it with `code`.

## 7. Messages

Five message types. Each is identified by the members it carries, and the rules in
Section 7.6 are normative — a receiver MUST apply them before acting.

### 7.1 Request — Client to Host

```json
{ "rorpc": "1.0", "id": 1, "namespace": "$", "ops": [ ... ] }
{ "rorpc": "1.0", "id": 3, "object": 1,      "ops": [ ... ] }
```

| Member      | Type    | Required  | Meaning                                         |
| ----------- | ------- | --------- | ----------------------------------------------- |
| `id`        | integer | yes       | Correlates the Response. Unique while in flight |
| `namespace` | string  | see below | Name to resolve into the root object            |
| `object`    | integer | see below | Handle to use as the root object                |
| `ops`       | array   | yes       | The chain, possibly empty                       |

Exactly one of `namespace` and `object` MUST be present. A Request carrying neither, or
both, is invalid and MUST draw a `-32600` error.

`id` MUST be unique among the Requests this Client currently has in flight. Reuse after a
Response has arrived is permitted; implementations typically use a counter from 1.

`ops` MUST be present and MUST be an array, even when empty — its presence is what
distinguishes a Request from a Response (Section 7.6).

### 7.2 Response — Host to Client

```json
{ "rorpc": "1.0", "id": 1, "result": "hi" }
{ "rorpc": "1.0", "id": 6, "error": { "__type__": "error", "__data__": { ... } } }
{ "rorpc": "1.0", "id": 5 }
```

| Member   | Type         | Required | Meaning                      |
| -------- | ------------ | -------- | ---------------------------- |
| `id`     | integer      | yes      | Copied from the Request      |
| `result` | any          | no       | The chain's value            |
| `error`  | error marker | no       | Why the chain did not finish |

A Response MUST NOT carry an `ops` member.

`result` and `error` MUST NOT both be present. When `error` is present the Request failed;
when it is absent the Request succeeded and `result` holds the value, **with an absent
`result` meaning the chain produced no value**. The third example above is the Response to a
successful `set`.

A receiver MUST treat `error` as present only when it is a well-formed error marker. An
implementation MUST NOT decide success by truthiness alone.

A Host MUST send exactly one Response per Request it accepts, and MUST NOT send a Response
for a message it rejected under Section 7.6.

### 7.3 Callback invocation — Host to Client

```json
{ "rorpc": "1.0", "callback": 1, "call": 1, "args": [0] }
```

| Member     | Type    | Required | Meaning                                       |
| ---------- | ------- | -------- | --------------------------------------------- |
| `callback` | integer | yes      | Entry in the Client's callback table          |
| `call`     | integer | yes      | Correlates the result. Unique while in flight |
| `args`     | array   | no       | Arguments. Absent means empty                 |

`call` identifies the **invocation**, not the function: the same callback may be running
more than once concurrently, and each invocation MUST carry its own `call`.

A Host MUST truncate `args` to the `arity` the function marker gave, if it gave one
(Section 11.2). With no `arity` it sends every argument.

### 7.4 Callback result — Client to Host

```json
{ "rorpc": "1.0", "call": 1, "result": 0 }
{ "rorpc": "1.0", "call": 2, "error": { "__type__": "error", "__data__": { ... } } }
```

| Member   | Type         | Required | Meaning                    |
| -------- | ------------ | -------- | -------------------------- |
| `call`   | integer      | yes      | Copied from the invocation |
| `result` | any          | no       | What the function returned |
| `error`  | error marker | no       | What the function threw    |

It MUST NOT carry a `callback` member; that is what distinguishes a result from an
invocation. The `result`/`error` rules of Section 7.2 apply unchanged.

A Client that receives an invocation for an unknown `callback` MUST ignore it. It MUST NOT
reply, since the Host is awaiting a value it cannot produce; the Host's invocation will
simply never settle. Implementations SHOULD consider a timeout at the application layer.

### 7.5 Release — Client to Host

```json
{ "rorpc": "1.0", "release": 1 }
```

| Member    | Type    | Required | Meaning                    |
| --------- | ------- | -------- | -------------------------- |
| `release` | integer | yes      | Handle the Host may forget |

A notification: there is no Response, and releasing an unknown handle is not an error.
After sending, the Client MUST NOT use that handle again. See Section 10.

### 7.6 Discrimination

A receiver MUST classify an incoming message by these tests, **in order**, and MUST ignore
any message that matches none of them:

**A Host** accepts:

1. `call` is an integer **and** `callback` is absent → Callback result (7.4)
2. `release` is an integer → Release (7.5)
3. `id` is an integer **and** `ops` is an array → Request (7.1)

**A Client** accepts:

1. `callback` is an integer → Callback invocation (7.3)
2. `id` is an integer **and** `ops` is **not** an array → Response (7.2)

These tests are not decoration. A Response carries an `id` exactly as a Request does, so a
Host that classified on `id` alone would read a Response as a Request, find no `namespace`
in it, and reply with an error carrying that same `id` — which the peer's Host would read as
a Request in turn. The `ops` test is what terminates that exchange. See Section 12.3.

## 8. Chain evaluation

On accepting a Request the Host resolves a **root**, then applies each op in order. It keeps
two values:

- `value` — the running result, initially the root;
- `receiver` — what a call binds its `this` to, initially the root.

### 8.1 Resolving the root

- `object` present: the handle table entry. A handle that is absent MUST fail the Request
  with `-32602`.
- `namespace` present: the implementation resolves the name. Resolution MAY be
  asynchronous. A name that resolves to nothing MUST fail with `-32601`.

### 8.2 Operations

| Op                                        | Effect                                                                           |
| ----------------------------------------- | -------------------------------------------------------------------------------- |
| `{ "type": "get", "key": k }`             | The receiver becomes the current value; the value becomes its member `k`         |
| `{ "type": "set", "key": k, "value": v }` | Member `k` of the value is set to `v`; the value and receiver become nothing     |
| `{ "type": "call", "args": a }`           | The value is invoked with `a` against the receiver; the receiver becomes nothing |

"Member" means whatever the host language reads for a named access — a field, a property,
an attribute, an entry of a map, or a getter. An implementation chooses that mapping and
MUST apply it consistently to `get` and `set`; see Section 16.2.

Notes, all normative:

- **`get` on an empty value yields nothing** rather than failing. A chain may read through
  a missing member and only fail when it tries to call one.
- **`set` on an empty value MUST fail** with `-32011`.
- **`call` on something not callable MUST fail** with `-32010`.
- **A call resolves its result.** If the invocation produces a deferred result — a promise,
  a future, a task — the Host MUST wait for it and send the settled value. A chain therefore
  cannot tell a synchronous operation from an asynchronous one, and a failed one becomes an
  error Response.
- **A call's result is unbound.** After a call the receiver is nothing, so a call applied
  directly to the result of another has no receiver. Languages that require one MUST fail
  the step rather than invent a binding.
- **`set` yields nothing.** The Response carries no `result`. A Host MUST NOT send the
  assigned value back: serializing it could mint a handle (Section 10) that the Client never
  receives and so can never release.

An empty `ops` array yields the root itself. Implementations that never send one MAY still
receive one and MUST handle it.

### 8.3 Ops are not values

`ops` is protocol structure, not payload. The `type` and `key` members are plain strings and
are NOT markers. Only `args` elements and a `set`'s `value` are values in the sense of
Section 6, and only those are marker-decoded.

## 9. Errors

### 9.1 Two kinds

An error Response does not distinguish, in its shape, between a fault of the protocol
(unknown module, dead handle, malformed request) and a fault of the application (the method
threw). `code` is what tells them apart, and is the reason it exists.

### 9.2 Codes

`code` SHOULD be present on every error a Host originates. Receivers MUST tolerate its
absence.

| Code     | Meaning             | Raised when                                              |
| -------- | ------------------- | -------------------------------------------------------- |
| `-32700` | Parse error         | Reserved; a message that cannot be parsed draws no reply |
| `-32600` | Invalid request     | Neither or both of `namespace`/`object`; malformed `ops` |
| `-32601` | Module not found    | `namespace` resolved to nothing                          |
| `-32602` | Invalid handle      | `object`, or an object marker, names no live handle      |
| `-32603` | Internal error      | The implementation itself failed                         |
| `-32013` | Key not permitted   | The Host's key policy refused a `get` or `set` (§13.2)   |
| `-32012` | Version mismatch    | Section 5.2                                              |
| `-32011` | Cannot set property | `set` against an empty value                             |
| `-32010` | Not a function      | `call` against a non-function                            |
| `-32000` | Application error   | The target threw or rejected                             |

`-32768` to `-32000` are reserved for this specification. Applications MUST NOT use codes in
that range and MAY use any other integer.

### 9.3 Stacks

`stack` is captured where the error arose — on the Host for an error Response, in the Client
for a callback that threw. Implementations SHOULD preserve it rather than overwrite it with
a stack from inside the RPC machinery, which describes only the plumbing.

A Host MAY omit `stack` entirely, and SHOULD do so when the peer is not trusted: a stack
discloses file paths and internal structure. See Section 13.3.

## 10. Handles

A **handle** is a positive integer naming an object the Host declined to copy.

### 10.1 Minting

Whether a value is copied or kept is an implementation decision, not a protocol one: a Host
MAY keep anything. It MUST allocate an identifier unique within the connection, MUST retain
a strong reference under it, and MUST emit an object marker in the value's place.

A handle is meaningful only within the connection that minted it. It MUST NOT be shared
across connections.

### 10.2 Lifetime

Handles are **not garbage collected**. A handle is an integer on the wire, and nothing about
a Client dropping its proxy is visible to the Host. An entry lives until:

- the Client sends a Release naming it (7.5),
- the call it belongs to completes, if it was made for one (10.4), or
- the connection ends and the Host discards the table.

This is the protocol's principal cost, and implementations MUST document it. A Host that
mints handles automatically will accumulate them for the life of a connection unless the
Client releases them.

Clients SHOULD release explicitly. A Client in a language with finalizers or weak
references MAY release on collection as a safety net, but whatever it registers MUST hold
only the handle integer: a finaliser that captures the proxy keeps the proxy reachable, so
it never runs.

### 10.3 Use after release

A Request rooted at a released handle, or carrying an object marker naming one, MUST fail
with `-32602`. A Host MUST NOT silently substitute an empty value.

Because identifiers may be reused after release, a Client that releases a handle and then
uses it races against a later allocation. Clients MUST NOT use a handle after releasing it.

### 10.4 Handles that belong to one call

A handle the Host mints while preparing a Callback invocation (§7.3) belongs to that
invocation. The Host MUST release it when the matching Callback result arrives, and MUST do
so after reading that result, so that a handle the Client sent back is still resolvable.

This exists because a callback is the one place a Host mints handles without being asked
to. Code that takes a callback commonly passes objects to it — an element, a row, a node —
and a Host with no rule here mints one handle per invocation, for as long as the iteration
runs. Nothing releases them, because the Client never asked for them and may not know they
exist.

**A Client MUST NOT use such a handle after its callback has returned.** A Client that needs
a value beyond the call MUST read it during the call. A Host MUST NOT extend the lifetime to
accommodate one that does not.

A handle that was already live when the invocation was prepared is not affected: it belongs
to whatever minted it. Only handles minted for this invocation's arguments are released.

## 11. Callbacks

### 11.1 Direction

A function in a Request's `args` or a `set`'s `value` stays in the Client. The Host receives
a stub; invoking it sends a Callback invocation and yields a deferred result that settles
when the Callback result arrives. The function itself never crosses.

A Client SHOULD reuse one identifier for one function, so that passing the same function
twice does not mint two entries.

Arguments that the Host cannot copy become handles, and those handles last only as long as
the invocation — see §10.4.

A whole exchange, for `rows.find(callback).text()`. The Client sends one Request; the Host
calls back twice while evaluating it, and answers once at the end:

```json
C→H  {"rorpc":"1.0","id":1,"namespace":"report","ops":[
       {"type":"get","key":"rows"},
       {"type":"get","key":"find"},
       {"type":"call","args":[{"__type__":"function","__data__":{"callback":1,"arity":1}}]},
       {"type":"get","key":"text"},
       {"type":"call","args":[]}]}

H→C  {"rorpc":"1.0","callback":1,"call":1,"args":["first row"]}
C→H  {"rorpc":"1.0","call":1,"result":false}
H→C  {"rorpc":"1.0","callback":1,"call":2,"args":["second row"]}
C→H  {"rorpc":"1.0","call":2,"result":true}

H→C  {"rorpc":"1.0","id":1,"result":"second row"}
```

Two things follow from the shape of this. The Host is evaluating a Request while it waits
for a Callback result, so it MUST be able to do both at once (§11.3). And the `call`
identifiers are the Host's, counted separately from the `id` of the Request they arose
under — one Request may produce any number of invocations, or none.

### 11.2 Arity

`arity` is a limit the Client may place on how many arguments it will accept. It is
optional, and the two cases are distinct:

- **Absent** — no limit. The Host MUST send every argument the call produced.
- **Present** — the Host MUST truncate `args` to that many before sending, and MUST NOT
  send more. An `arity` of `0` means the Client wants none.

A Host MUST NOT infer anything else from it. In particular an `arity` lower than the number
of arguments at hand is not an error, and a Host MUST NOT refuse the call over it.

Two reasons a Client sets one. The first is that its language will not tolerate the extras:
a callable that accepts a fixed number of arguments raises on a surplus in most statically
typed languages, and in some dynamic ones. The second is that the extras may not be
sendable at all — code that takes a callback commonly passes it more than it asked for, an
index and also the element, a value and also the whole collection, and those additional
arguments are often precisely the objects that cannot cross a channel.

A Client whose language tolerates surplus arguments, and whose callback can take whatever
arrives, MAY omit `arity`. Section 16.3 covers how to choose.

**Omitting it is not free.** Everything the caller passed is then serialized and sent, and
a Client that sends no `arity` should expect all three of these:

- **Objects the Host cannot copy become handles.** A callback invoked once per row, given
  the row as well as the index, costs one handle per invocation. They are released when
  each invocation completes (§10.4), so they do not accumulate, but they are still minted,
  sent and released for arguments nobody wanted.
- **The extras may not be representable.** An argument that cannot be copied and cannot be
  kept as a handle fails the invocation, and with it the Request that caused it — for an
  argument the callback would have ignored.
- **The Client may not tolerate them.** A callable with a fixed signature raises on a
  surplus in many languages. A Client that omits `arity` MUST be prepared to drop the extra
  arguments itself, at the point it dispatches to the callable.

Sending an `arity` moves all three problems to the one side that can settle them cheaply:
the Host simply does not serialize what was not asked for.

### 11.3 Nesting

A callback may itself issue Requests. A Host MUST therefore be able to accept and answer a
Request while a callback invocation it sent is still outstanding. An implementation that
serialized all work would deadlock here.

## 12. Ordering and concurrency

### 12.1 Requests

Requests are independent. A Host MAY evaluate several concurrently and MAY answer out of
order; `id` is what correlates them. A Client MUST NOT assume that Request _n_ was evaluated
before Request _n+1_.

This matters more than it first appears: a Host whose name resolution is asynchronous will
routinely finish a later Request first.

### 12.2 Writes

A Client that records chains from ordinary syntax usually has no way to make an assignment
wait: in most languages an assignment is a statement, or an expression that yields the value
assigned, and it cannot yield a deferred result for a caller to wait on. Such a Client
dispatches a write and moves on. Combined with 12.1, a read issued after a write can
therefore be evaluated **before** it.

A Client that offers read-after-write ordering MUST enforce it, by holding later Requests
until the writes ahead of them have been answered. This specification does not require that
guarantee, but an implementation MUST document which it provides.

### 12.3 Shared transports

RO/RPC identifiers are per-connection (T4). On a transport where more than one pair of peers
can hear each other — a `BroadcastChannel` with three endpoints, a cross-tab bus — two
Clients will both number their Requests from 1, and a Response to one is indistinguishable
from a Response to the other.

The discrimination rules of Section 7.6 make this _survivable_: peers no longer answer each
other's Responses, which without them produces an unbounded exchange between two Hosts.
They do not make it _correct_. Deployments MUST give each pair of peers a transport of its
own, or add addressing above this protocol.

## 13. Security considerations

### 13.1 Resolution is the boundary

Everything a name resolves to is fully reachable: every property, every method, every
object reachable from it, without limit. Exposing a library object exposes the library.

Over a trusted transport (a page and its own worker) that is the point. Over a network
transport it is the whole security boundary, and a Host SHOULD resolve names to a narrow
object of permitted operations rather than to a general-purpose API.

### 13.2 Untrusted input

A Host evaluates chains its peer chose. Every key is an attacker-chosen string and every
argument an attacker-chosen value, and the protocol places no limit on a chain's length,
its argument count, or how long evaluation may take. A Host exposed to untrusted peers
SHOULD impose its own limits on all three.

**Which names are dangerous is a property of the host language, not of this protocol.**
Most languages reach something hazardous through ordinary attribute access — an object's
type, its defining scope, its module, the objects its type can enumerate — and reaching one
of them from an exposed object is usually enough to escape whatever the exposure intended.
The paths differ by language, and a list written here would be wrong somewhere.

A refusal SHOULD be reported with code `-32013` (§9.2), so that a Client can tell a policy
refusal from a missing member.

Note that refusing writes is not enough. The write that does the damage commonly has an
innocent key of its own — it is the _reads_ before it that walked somewhere they should not
have — so a policy that only inspects `set` keys stops nothing.

An implementation MUST therefore decide for itself which keys a chain may traverse, in the
terms of its own language and runtime, and MUST document the policy it applies. This
specification does not define one, and an implementation MUST NOT assume its peer enforces
anything: a Host is responsible for what a chain can reach on the Host, whatever the Client
is written in.

Section 13.1 remains the first line of defence. A narrow object exposed by `resolve()`
bounds what any chain can reach regardless of which keys are permitted, and is easier to
reason about than a filter over names.

### 13.3 Disclosure

Error `stack` values disclose paths and internal structure, and `message` values often
disclose more. A Host facing untrusted peers SHOULD omit `stack` and SHOULD
replace application error messages with a code.

### 13.4 Reserved shapes

An application value that is an object with both a `__type__` string and a `__data__` object
cannot be transmitted: it will be decoded as a marker. Implementations SHOULD document this.
Values of that shape are rare by construction, which is why those names were chosen.

## 14. Differences from JSON-RPC 2.0

|               | JSON-RPC 2.0                       | RO/RPC 1.0                                                   |
| ------------- | ---------------------------------- | ------------------------------------------------------------ |
| Unit of work  | One named method and its arguments | A chain of reads, writes and calls                           |
| State         | Stateless                          | Stateful: handle and callback tables live for the connection |
| Symmetry      | Either peer may call               | Fixed roles; a Host never issues a Request                   |
| Identity      | `"jsonrpc": "2.0"`                 | `"rorpc": "1.0"`                                             |
| Correlation   | `id`, may be a string or number    | `id`, integer, plus `call` for callbacks                     |
| Notifications | A Request with no `id`             | Only Release; everything else is answered                    |
| Batching      | An array of Requests               | Not supported — a chain is already the batch                 |
| Errors        | `{ code, message, data }`          | An error marker; `code` plays the same role                  |
| Higher-order  | No                                 | Functions cross as callbacks, invoked backwards              |

The absence of batching is deliberate: the chain is what JSON-RPC batching is usually
reaching for, and a chain is strictly more expressive, since each step can consume the one
before it.

## 15. Conformance

### 15.1 Minimal conformance

A conforming **Host** MUST: accept the three Client message types (7.6); evaluate chains per
Section 8; answer exactly one Response per accepted Request; encode errors per Section 9;
maintain a handle table per Section 10; and truncate callback arguments per 11.2.

A conforming **Client** MUST: accept the two Host message types (7.6); correlate by `id` and
`call`; encode functions as markers and answer invocations; and never use a released handle.

Both MUST emit `rorpc` on every message and MUST apply Section 5.2 on mismatch.

### 15.2 The reference implementation

[`@jcubic/mitty`](https://github.com/jcubic/mitty) is the reference implementation. As of
**0.5.0** it conforms, with one gap:

| Requirement                             | 0.5.0                                                   |
| --------------------------------------- | ------------------------------------------------------- |
| `rorpc` member on every message (§5)    | Implemented.                                            |
| `__data__` as an object (§6)            | Implemented.                                            |
| `code` on Host-originated errors (§9.2) | Implemented, and carried onto the reconstructed error.  |
| Call-scoped handles (§10.4)             | Implemented.                                            |
| `arity` from a parameter count (§16.3)  | Implemented from the required count, limits documented. |
| A documented key policy (§13.2)         | Implemented. `safe_key()` by default, overridable.      |
| Everything else                         | Implemented.                                            |

Versions up to **0.4.x** speak an earlier, unversioned format with positional `__data__`
arrays and no codes. They do not interoperate with 1.0 in either direction: a 1.0 peer
rejects their messages for want of a version, and they ignore a 1.0 error marker's named
members. Both ends of a connection MUST be upgraded together.

Ordering (§12.2): mitty's Client **does** provide read-after-write ordering, by holding
Requests while a write is in flight.

---

## 16. Language mapping

The protocol carries only what JSON defines. Everything below is a place where a host
language's own conventions have to be mapped onto that, and where two implementations will
disagree unless each says what it chose. An implementation MUST document its answers.

### 16.1 Empty values

RO/RPC distinguishes three states for an optional member: present with a value, present as
`null`, and absent (§4).

A language with two empty values maps them directly — one to `null`, one to absence. A
language with one maps that one to `null`, and MUST choose what absence means to it; the
natural choice is the same empty value, which makes the two indistinguishable locally. That
is permitted: the distinction matters on the wire, not in every language that speaks it.

A Host MUST NOT reject a Request because an argument arrived as `null` where it expected
absence, or the reverse. A Client MUST NOT assume a Host preserved the difference.

### 16.2 Members

`get` and `set` name a member of a value (§8.2). What that resolves to is the
implementation's choice: a field, a property, an attribute, a getter or setter pair, an
entry in a map, or an index.

Two rules bind that choice. It MUST be consistent — a `set` MUST write what a `get` with
the same key would read. And a member that exists but cannot be read MUST fail the Request
rather than report absence, so that a Client can tell "no such member" from "not allowed".

An implementation MAY expose indices as decimal string keys. It MUST say whether it does,
because a Client cannot discover it.

### 16.3 Callables and arity

A `call` requires the current value to be invocable. What qualifies is the implementation's
choice: a function, a method reference, a bound delegate, an object with a single abstract
method, or an object that defines invocation.

`arity` (§11.2) is optional. A Client that can say how many arguments a callable takes
SHOULD send one, because of what omitting it costs (§11.2).

**The count a language reports may not be the count you want.** Introspection commonly
gives the number of parameters _before_ the first optional or variadic one — what the
callable requires, not what it accepts. A limit taken from that number caps the call at the
required count, so an optional parameter never receives a value and a callable that takes
only a variadic receives nothing.

Languages differ in how much they will tell you, and the choice follows from that:

- Where the two counts are both available — PHP's `getNumberOfParameters` beside
  `getNumberOfRequiredParameters`, and the equivalent elsewhere — a Client SHOULD send the
  count it _accepts_, so that optional parameters can be filled. A variadic callable has no
  such count, and a Client SHOULD omit `arity` for one.
- Where only one count is available and it is the required one, a Client MAY still send it,
  provided it **documents that optional and variadic parameters are not filled**. That is a
  real restriction on what callbacks may be written, and users have to be told.
- Where no count is available, a Client MUST either omit `arity` and handle the surplus
  itself (§11.2), or take the number from the caller.

An implementation MUST document which of these it does.

### 16.4 Errors

`name` (§6.3) is a string, and carries whatever the originating language calls the error.
A receiver MUST NOT depend on a particular vocabulary: `name` is for a human reading a log.

A receiver SHOULD reconstruct the error as its own language's error type, and MUST NOT fail
to deliver an error because `name` matched nothing it knows. `code` is the member to branch
on (§9.2); it is an integer precisely so that it survives a language boundary unchanged.

---

## Appendix A: schema

Written as TypeScript declarations, which are used here only as a compact notation for JSON
shapes. Nothing about the protocol requires TypeScript or JavaScript.

```typescript
type Version = `${number}.${number}`;

type Value = null | boolean | number | string | Value[] | { [k: string]: Value } | Marker;

type Marker = ObjectMarker | FunctionMarker | ErrorMarker;
type ObjectMarker = { __type__: 'object'; __data__: { handle: number } };
type FunctionMarker = {
  __type__: 'function';
  __data__: { callback: number; arity?: number };
};
type ErrorMarker = {
  __type__: 'error';
  __data__: { name: string; message: string; stack?: string; code?: number };
};

type Op =
  | { type: 'get'; key: string }
  | { type: 'set'; key: string; value: Value }
  | { type: 'call'; args: Value[] };

// Client -> Host
type Request = { rorpc: Version; id: number; ops: Op[] } & (
  { namespace: string; object?: never } | { object: number; namespace?: never }
);
type CallbackResult = { rorpc: Version; call: number } & (
  { result?: Value; error?: never } | { error: ErrorMarker; result?: never }
);
type Release = { rorpc: Version; release: number };

// Host -> Client
type Response = { rorpc: Version; id: number } & (
  { result?: Value; error?: never } | { error: ErrorMarker; result?: never }
);
type Invocation = { rorpc: Version; callback: number; call: number; args?: Value[] };
```

## Appendix B: an annotated session

A real transcript from the reference implementation, with the `rorpc` member added as 1.0
requires. `$` resolves to an object with `stat()`, `each()` and `doc`; `cfg` resolves to a
plain object.

**A chain of two reads.** Two steps, one message.

```json
C→H  {"rorpc":"1.0","id":1,"namespace":"$","ops":[{"type":"get","key":"doc"},{"type":"get","key":"title"}]}
H→C  {"rorpc":"1.0","id":1,"result":"hi"}
```

**A call returning an object the Host keeps.** The result is a marker, and handle 1 is now
live.

```json
C→H  {"rorpc":"1.0","id":2,"namespace":"$","ops":[{"type":"get","key":"stat"},{"type":"call","args":[]}]}
H→C  {"rorpc":"1.0","id":2,"result":{"__type__":"object","__data__":{"handle":1}}}
```

**A chain rooted at that handle.** `object` replaces `namespace`.

```json
C→H  {"rorpc":"1.0","id":3,"object":1,"ops":[{"type":"get","key":"isFile"},{"type":"call","args":[]}]}
H→C  {"rorpc":"1.0","id":3,"result":true}
```

**A callback with no limit.** The function stays in the Client; the Host invokes it twice,
concurrently, under one `callback` and two distinct `call` identifiers. The marker carries
no `arity`, so both arguments the caller passed arrive. The Response comes only after both
results.

```json
C→H  {"rorpc":"1.0","id":4,"namespace":"$","ops":[{"type":"get","key":"each"},{"type":"call","args":[{"__type__":"function","__data__":{"callback":1}}]}]}
H→C  {"rorpc":"1.0","callback":1,"call":1,"args":[0,0]}
H→C  {"rorpc":"1.0","callback":1,"call":2,"args":[1,10]}
C→H  {"rorpc":"1.0","call":1,"result":0}
C→H  {"rorpc":"1.0","call":2,"result":11}
H→C  {"rorpc":"1.0","id":4,"result":[0,11]}
```

**The same callback, limited to one argument.** `arity` is 1, so the Host truncates. The
second argument is never serialized — which is the point when it is something the Host
would otherwise have to keep a handle for.

```json
C→H  {"rorpc":"1.0","id":5,"namespace":"$","ops":[{"type":"get","key":"each"},{"type":"call","args":[{"__type__":"function","__data__":{"callback":2,"arity":1}}]}]}
H→C  {"rorpc":"1.0","callback":2,"call":3,"args":[0]}
H→C  {"rorpc":"1.0","callback":2,"call":4,"args":[1]}
C→H  {"rorpc":"1.0","call":3,"result":0}
C→H  {"rorpc":"1.0","call":4,"result":1}
H→C  {"rorpc":"1.0","id":5,"result":[0,1]}
```

**A write.** The Response carries no `result` — §7.2, §8.2.

```json
C→H  {"rorpc":"1.0","id":6,"namespace":"cfg","ops":[{"type":"set","key":"title","value":"set"}]}
H→C  {"rorpc":"1.0","id":6}
```

**A release.** No Response.

```json
C→H  {"rorpc":"1.0","release":1}
```

**A protocol error and an application error**, told apart by `code`.

```json
C→H  {"rorpc":"1.0","id":7,"namespace":"$","ops":[{"type":"get","key":"nope"},{"type":"call","args":[]}]}
H→C  {"rorpc":"1.0","id":7,"error":{"__type__":"error","__data__":{"name":"TypeError","message":"mitty: $.nope is not a function","code":-32010}}}

C→H  {"rorpc":"1.0","id":8,"namespace":"ghost","ops":[{"type":"get","key":"x"},{"type":"call","args":[]}]}
H→C  {"rorpc":"1.0","id":8,"error":{"__type__":"error","__data__":{"name":"Error","message":"mitty: unknown module 'ghost'","code":-32601}}}
```

---

Copyright (c) 2026 [Jakub T. Jankiewicz](https://jakub.jankiewicz.org/); source on [GitHub](https://github.com/jcubic/rorpc)

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/)
