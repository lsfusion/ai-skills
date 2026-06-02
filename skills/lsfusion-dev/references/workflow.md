# Writing and verifying lsFusion code

## The code-writing loop

lsFusion is a declarative platform with syntax unlike mainstream languages. Do
not write it from memory. For every code change:

1. **Guidance** — if the lsFusion rules are not already in context, call
   `lsfusion_get_guidance` and follow them.
2. **Look up syntax** — call `lsfusion_retrieve_docs` for the specific
   construct you are about to use (operators, `FORM` clauses, `GROUP`, events,
   etc.). Query in English; rephrase if recall is weak. Use `type: "language"`
   for syntax and `type: "paradigm"` for concepts.
3. **Decide elements in order** — modules/classes → properties → actions →
   forms → events/constraints. Settle the data model before the UI.
4. **Write small** — add one coherent slice, then run and read the log.
5. **Restart and check** — `lsfdev.ps1 restart`, then `log`. lsFusion reports
   parse and load errors in the server log with file and line.

Put `.lsf` files in the project folder; they are loaded automatically. Splitting
logic into focused modules (one feature area each) is preferred over one large
module — see the module rules from `lsfusion_get_guidance`.

## A minimal working module

This is a starting point only — confirm exact syntax for anything beyond it
with `lsfusion_retrieve_docs`.

```lsf
MODULE HelloWorld;

REQUIRE System;

CLASS Greeting 'Greeting';

name 'Name' = DATA STRING[100] (Greeting);
message 'Message' = DATA STRING[200] (Greeting);

FORM greetings 'Greetings'
    OBJECTS g = Greeting
    PROPERTIES(g) name, message, NEW, DELETE
;

NAVIGATOR {
    NEW greetings;
}
```

Why this works as a first run:
- `REQUIRE System` pulls in the built-in modules.
- A form only appears in the UI menu if it is added to the `NAVIGATOR`.
- `NEW` / `DELETE` on the form let the user add and remove rows, so there is
  something interactive to see immediately.
- Only primitive (`STRING`) properties are shown — never put object-valued
  properties or internal ids on a form.

If the project has several modules, set the top module once so the server
knows the entry point: `lsfdev.ps1 setup -TopModule HelloWorld -Force` (or
leave it blank to load every module found).

## Verifying the result

After `restart` shows **started** and `status` shows both processes up, verify
on two levels.

### UI rendering — headless Chrome

`lsfdev.ps1 verify` screenshots `http://localhost:8080/` to
`.lsfusion-dev/verify.png`. **Read that PNG with the Read tool** to see the
page. Plain headless Chrome cannot log in, so it lands on the login screen —
that already confirms the web stack serves correctly. For a logged-in view,
use `lsfdev.ps1 open` and let the user sign in (user `admin`, empty password).

### Business logic — HTTP Action API

The application server exposes an HTTP API on port `7651` that runs lsFusion
code with no browser login. `lsfdev.ps1 api -Script "<action code>"` posts
action code to the `EVAL ACTION` endpoint (parameters are `$1`, `$2`, ...).

This is the reliable way to check that logic behaves: a script with a syntax
error or a failing constraint comes back as an HTTP error; a working script
returns `200`. To read actual data values back, the action must write them to
the HTTP response (for example via `EXPORT`). Look up the exact form with
`lsfusion_retrieve_docs` — query "Access from an external system",
"EXPORT action", and "Action API". Keep verification scripts small.

## After changes

Editing any `.lsf` file requires `lsfdev.ps1 restart` (application server only;
Tomcat keeps running). Then re-`verify`. Iterate until the log is clean and the
screenshot looks right.
