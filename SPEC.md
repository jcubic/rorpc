# RO/RPC — Remote Object / Remote Procedure Call

**Version 1.0** · Status: Draft · 2026-09-27

RO/RPC is a stateless, transport-agnostic protocol for using an object that lives somewhere
else. Where [JSON-RPC](https://www.jsonrpc.org/specification) calls a named method with
arguments, RO/RPC replays a **chain** of property reads, property writes and calls against
an object that never leaves its own context — a DOM node, a jQuery object, a cheerio
document, a database handle, anything whose methods are the point of it.

```js
await $('#list').find('li').first().text();

await document.querySelector('body').style.setProperty('background', '#555');
```

Four steps, one message, and the object stayed where it was.

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
16. [Appendix A: schema](#appendix-a-schema)
17. [Appendix B: an annotated session](#appendix-b-an-annotated-session)

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

**Absent means `undefined`.** JSON has no `undefined`, and serializers routinely drop object
keys whose value is `undefined`. RO/RPC relies on this: a Response with no `result` key
denotes the JavaScript value `undefined`, not a missing field. See Section 7.2.

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

`__data__` is an object, not a positional array. Members are named, so a marker reads
without reference to this document, unknown members can be added without renumbering, and
an optional member is simply absent rather than a `null` holding a place.

The dunder names are deliberate. `{ type, data }` is an ordinary shape to find in
application data; `{ __type__, __data__ }` is not. An application value of the reserved shape
cannot be transmitted; see Section 13.4.

A receiver that encounters a `__type__` it does not recognise MUST treat the object as an
ordinary JSON object (forward compatibility, Section 5.1).

### 6.1 Object marker

```json
{ "__type__": "object", "__data__": { "handle": 1 } }
```

| Member   | Type    | Required | Meaning                                |
| -------- | ------- | -------- | -------------------------------------- |
| `handle` | integer | yes      | Entry in the Host's handle table (§10) |

Direction: **both**. From Host to Client it introduces a handle. From Client to Host it
refers to one already introduced, and the Host MUST substitute the object it names before
evaluation.

### 6.2 Function marker

```json
{ "__type__": "function", "__data__": { "callback": 1, "arity": 1 } }
```

| Member     | Type    | Required | Meaning                                     |
| ---------- | ------- | -------- | ------------------------------------------- |
| `callback` | integer | yes      | Entry in the Client's callback table (§11)  |
| `arity`    | integer | yes      | Parameters the function declares; see §11.2 |

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

Only these four members are defined. **Other own properties of an error are not
transmitted** — a Node `ENOENT` error arrives without its `code` property, and a
`ValidationError` without its `errors` array. An application that needs more MUST put it in
the message or use `code`.

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
`result` denoting `undefined`**. The third example above is the Response to a successful
`set`.

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

A Host MUST truncate `args` to the `arity` the function marker declared (Section 11.2).

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
  asynchronous. A name that resolves to `null` or `undefined` MUST fail with `-32601`.

### 8.2 Operations

| Op                                        | Effect                                                                |
| ----------------------------------------- | --------------------------------------------------------------------- |
| `{ "type": "get", "key": k }`             | `receiver = value`; `value = value[k]`                                |
| `{ "type": "set", "key": k, "value": v }` | `value[k] = v`; then `value = undefined`, `receiver = undefined`      |
| `{ "type": "call", "args": a }`           | `value = await value.apply(receiver, a)`; then `receiver = undefined` |

Notes, all normative:

- **`get` on `null` or `undefined` yields `undefined`** rather than failing. A chain may
  read through a missing property and only fail when it tries to call one.
- **`set` on `null` or `undefined` MUST fail** with `-32011`.
- **`call` on a non-function MUST fail** with `-32010`.
- **A call awaits its result.** If a method returns a thenable, the Host MUST await it and
  send the settled value. A chain therefore cannot distinguish a synchronous method from an
  asynchronous one, and a rejected promise becomes an error Response.
- **A call's result is unbound.** After a call, `receiver` is `undefined`, so
  `a.b()()` invokes the returned function with no `this`. This matches JavaScript.
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
| `-32601` | Module not found    | `namespace` resolved to `null` or `undefined`            |
| `-32602` | Invalid handle      | `object`, or an object marker, names no live handle      |
| `-32603` | Internal error      | The implementation itself failed                         |
| `-32012` | Version mismatch    | Section 5.2                                              |
| `-32011` | Cannot set property | `set` against `null` or `undefined`                      |
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

- the Client sends a Release naming it (7.5), or
- the connection ends and the Host discards the table.

This is the protocol's principal cost, and implementations MUST document it. A Host that
mints handles automatically will accumulate them for the life of a connection unless the
Client releases them. Clients SHOULD release explicitly; a `FinalizationRegistry` keyed on
the handle integer — never on the proxy, which would keep it reachable — is a reasonable
safety net.

### 10.3 Use after release

A Request rooted at a released handle, or carrying an object marker naming one, MUST fail
with `-32602`. A Host MUST NOT silently substitute `undefined`.

Because identifiers may be reused after release, a Client that releases a handle and then
uses it races against a later allocation. Clients MUST NOT use a handle after releasing it.

## 11. Callbacks

### 11.1 Direction

A function in a Request's `args` or a `set`'s `value` stays in the Client. The Host receives
a stub; invoking it sends a Callback invocation and yields a promise that settles when the
Callback result arrives. The function itself never crosses.

A Client SHOULD reuse one identifier for one function, so that passing the same function
twice does not mint two entries.

### 11.2 Arity

`args` MUST be truncated to the declared `arity`.

This is not an optimisation. Callers such as jQuery and cheerio pass extra arguments — event
objects, DOM elements — that cannot be serialized, and would fail the invocation. Declaring
`index => …` where the caller passes `(index, element)` is how a Client says it wants only
the first.

A consequence: a Client cannot receive an argument it did not declare, and rest parameters
declare an arity of zero. This is deliberate.

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

`set` has no natural caller to await it — in JavaScript `a.b = c` evaluates to `c` and the
assignment cannot yield a promise — so a Client typically dispatches a write without waiting.
Combined with 12.1, a read issued after a write can therefore be evaluated **before** it.

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

A Host evaluates chains chosen by its peer. Property names are attacker-chosen strings, so
implementations MUST NOT let a chain reach the prototype chain in a way that allows
pollution, and SHOULD reject `__proto__`, `constructor` and `prototype` as `get` and `set`
keys when the peer is not trusted.

A `call` runs peer-chosen code paths with peer-chosen arguments. There is no depth,
argument-count or time limit in this protocol; a Host exposed to untrusted peers SHOULD
impose its own.

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

| Requirement                             | 0.5.0                                                  |
| --------------------------------------- | ------------------------------------------------------ |
| `rorpc` member on every message (§5)    | Implemented.                                           |
| `__data__` as an object (§6)            | Implemented.                                           |
| `code` on Host-originated errors (§9.2) | Implemented, and carried onto the reconstructed error. |
| Prototype-key rejection (§13.2)         | **Not implemented.** `resolve()` is the only boundary. |
| Everything else                         | Implemented.                                           |

Versions up to **0.4.x** speak an earlier, unversioned format with positional `__data__`
arrays and no codes. They do not interoperate with 1.0 in either direction: a 1.0 peer
rejects their messages for want of a version, and they ignore a 1.0 error marker's named
members. Both ends of a connection MUST be upgraded together.

Ordering (§12.2): mitty's Client **does** provide read-after-write ordering, by holding
Requests while a write is in flight.

---

## Appendix A: schema

```typescript
type Version = `${number}.${number}`;

type Value = null | boolean | number | string | Value[] | { [k: string]: Value } | Marker;

type Marker = ObjectMarker | FunctionMarker | ErrorMarker;
type ObjectMarker = { __type__: 'object'; __data__: { handle: number } };
type FunctionMarker = {
  __type__: 'function';
  __data__: { callback: number; arity: number };
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

**A callback.** The function stays in the Client; the Host invokes it twice, concurrently,
under one `callback` and two distinct `call` identifiers. `arity` is 1, so the Host sends one
argument even though it called with two. The Response arrives only after both results.

```json
C→H  {"rorpc":"1.0","id":4,"namespace":"$","ops":[{"type":"get","key":"each"},{"type":"call","args":[{"__type__":"function","__data__":{"callback":1,"arity":1}}]}]}
H→C  {"rorpc":"1.0","callback":1,"call":1,"args":[0]}
H→C  {"rorpc":"1.0","callback":1,"call":2,"args":[1]}
C→H  {"rorpc":"1.0","call":1,"result":0}
C→H  {"rorpc":"1.0","call":2,"result":2}
H→C  {"rorpc":"1.0","id":4,"result":[ ... ]}
```

**A write.** The Response carries no `result` — §7.2, §8.2.

```json
C→H  {"rorpc":"1.0","id":5,"namespace":"cfg","ops":[{"type":"set","key":"title","value":"set"}]}
H→C  {"rorpc":"1.0","id":5}
```

**A release.** No Response.

```json
C→H  {"rorpc":"1.0","release":1}
```

**A protocol error and an application error**, told apart by `code`.

```json
C→H  {"rorpc":"1.0","id":6,"namespace":"$","ops":[{"type":"get","key":"nope"},{"type":"call","args":[]}]}
H→C  {"rorpc":"1.0","id":6,"error":{"__type__":"error","__data__":{"name":"TypeError","message":"$.nope is not a function","code":-32010}}}

C→H  {"rorpc":"1.0","id":7,"namespace":"ghost","ops":[{"type":"get","key":"x"},{"type":"call","args":[]}]}
H→C  {"rorpc":"1.0","id":7,"error":{"__type__":"error","__data__":{"name":"Error","message":"unknown module 'ghost'","code":-32601}}}
```

---

Copyright (c) 2026 [Jakub T. Jankiewicz](https://jakub.jankiewicz.org/)

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/)
