# RO/RPC

**Remote Object / Remote Procedure Call** — a stateless, transport-agnostic protocol for
using an object that lives somewhere else.

📄 **[Read the specification](https://rorpc.org/)** · [SPEC.md](SPEC.md)

Version 1.0 · Status: **Working Draft**

## What it is

Where [JSON-RPC](https://www.jsonrpc.org/specification) calls one named method with
arguments, RO/RPC replays a **chain** of property reads, property writes and calls against
an object that never leaves the context that owns it.

```
report.section("summary").rows.first().text()
```

```json
{
  "rorpc": "1.0",
  "id": 1,
  "namespace": "report",
  "ops": [
    { "type": "get", "key": "section" },
    { "type": "call", "args": ["summary"] },
    { "type": "get", "key": "rows" },
    { "type": "get", "key": "first" },
    { "type": "call", "args": [] },
    { "type": "get", "key": "text" },
    { "type": "call", "args": [] }
  ]
}
```

One message, and the object stayed where it was. A protocol that called one method at a time
would need four round trips and three intermediate objects it could not send.

The object it stands for can be anything whose **behaviour**, rather than its data, is the
point of it: a user interface element, a parsed document, a database cursor, a file handle.
What cannot be copied becomes a **handle** and stays where it is.

The protocol says nothing about how messages are carried. A Web Worker, a WebSocket, two
browser tabs, two processes, two languages — anything that can pass a string both ways.

## Status

A Working Draft. While the status is Draft the version stays at `1.0`; changes are recorded
in the [changelog](SPEC.md#changelog) with dates instead. The version starts to move when
the document leaves Draft.

Comments, questions and implementation reports are welcome in
[issues](https://github.com/jcubic/rorpc/issues).

## Implementations

| Language   | Project                                          |
| ---------- | ------------------------------------------------ |
| JavaScript | [@jcubic/mitty](https://github.com/jcubic/mitty) |

Implementing it elsewhere? Open a pull request and add a row.

## Building this site

[rorpc.org](https://rorpc.org/) is `SPEC.md` rendered into `template.html`.

```bash
npm install
make
```

The result is `dist/index.html`. GitHub Actions runs the same two commands on every push to
`master` and publishes it to Pages.

## License

[CC0 1.0 Universal](LICENSE).

To the extent possible under law, [Jakub T. Jankiewicz](https://jakub.jankiewicz.org/) has
waived all copyright and related or neighbouring rights to this specification. It is
dedicated to the public domain — implement it, copy it, fork it, no permission needed.
