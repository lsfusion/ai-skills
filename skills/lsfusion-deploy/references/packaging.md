# Packaging an lsFusion app for deploy

What needs to be inside the jar that lands in `/var/lib/lsfusion/`. Read this when SKILL.md's brief "package the application" section doesn't answer your question.

## The classpath shape lsFusion expects

When the app-server unit boots, it scans the classpath for:

1. **`lsfusion.properties` at the root** — read directly via `ClassLoader.getResource("lsfusion.properties")`. Sets `logics.topModule`, deny flags, locale, user defaults. Multiple jars can each ship one; classpath order decides which wins.
2. **`.lsf` modules at paths that match their `MODULE` declaration** — e.g. `MODULE Foo;` in `accounting/Foo.lsf` is fine, but moving the file to `bar/Foo.lsf` breaks the loader. Modules are discovered by scanning the classpath for `*.lsf`, then matched against the `MODULE <Name>` line inside.
3. **`.class` files** for any Java helpers referenced as INTERNAL actions in `.lsf`. The package path on classpath must match the Java `package` declaration.
4. **Static resources** at the locations modules expect: `.jrxml` reports, `.sql` files, icons, web assets. Whatever a module does with `IMAGE 'foo.png'` or `READ 'bar.sql'` is resolved against the classpath relative to the calling module's directory.

There is **no manifest, descriptor, or registry** to write — discovery is by classpath scanning. That's why "just jar up the right directory tree" works.

## Layout templates

### From a Maven project's `target/classes/`

After `mvn -DskipTests compile` finishes, `target/classes/` already has the exact tree the platform wants. Why each piece is there:

```
target/classes/
├── lsfusion.properties               # copied from src/main/resources/
├── MyApp.lsf                         # copied from src/main/lsfusion/
├── MyAppResourceBundle.properties    # copied from src/main/resources/
├── MyAppResourceBundle_ru.properties # localization bundles get the same treatment
├── accounting/                       # copied from src/main/lsfusion/accounting/
│   ├── Accounting.lsf
│   └── ...
├── images/                           # copied from src/main/resources/images/
├── sql/                              # copied from src/main/resources/sql/
├── web/                              # copied from src/main/resources/web/
├── builddef.lst                      # AspectJ build descriptor — leftover from the compile, harmless at runtime
├── com/                              # compiled .class files from src/main/java/com/...
│   └── example/
│       └── crypto/
│           ├── CipherAction.class
│           └── ...
└── region/                           # mixed: .lsf modules AND .class files can share a dir tree
    └── us/
        ├── Sales.lsf
        └── integration/
            └── ImportAction.class
```

Maven's resource-copy plugin treats `src/main/lsfusion/` and `src/main/resources/` as resource roots — everything in them ends up directly under `target/classes/`. Java sources are compiled to `.class` at their package path under the same root. Result: a single tree where `.lsf`, `.class`, and resources coexist, and that's exactly what the classpath needs.

Jar it as-is:

```bash
jar cf app.jar -C target/classes .
```

Or on Windows from PowerShell (`JAVA_HOME` is often unset even when Java is
installed, or set but pointing at a JRE without `jar.exe` — probe it, then
fall back to `jar.exe` on `PATH`, then to the one next to `java.exe`):

```powershell
$jar = if ($env:JAVA_HOME -and (Test-Path "$env:JAVA_HOME\bin\jar.exe")) { "$env:JAVA_HOME\bin\jar.exe" }
       elseif (Get-Command jar.exe -ErrorAction SilentlyContinue) { (Get-Command jar.exe).Source }
       else { Join-Path (Split-Path (Get-Command java).Source) "jar.exe" }
& $jar --create --file=app.jar -C target\classes .
```

The `-C` switch changes directory before reading entries, so the jar's internal paths are `accounting/...`, not `target/classes/accounting/...`. That's required — the platform looks for resources at jar root.

### Hand-assembled, no Maven

For a from-scratch project, replicate the same layout in a `staging/` directory. Minimum:

```
staging/
└── lsfusion.properties           # required at root
    # contains:
    #   logics.topModule = MyApp
    #   db.denyDropModules = false
└── MyApp.lsf                     # the entry module (matches logics.topModule)
```

Larger projects mirror modules to subdirs:

```
staging/
├── lsfusion.properties
├── MyApp.lsf                     # MODULE MyApp; REQUIRE Inventory, Sales, ...
├── inventory/
│   ├── Inventory.lsf             # MODULE Inventory;
│   └── Warehouse.lsf             # MODULE Warehouse;
├── sales/
│   └── Sales.lsf                 # MODULE Sales;
└── reports/
    └── invoice.jrxml             # referenced by REPORT in some .lsf
```

Then pack into a jar:

```powershell
Compress-Archive -Path staging\* -DestinationPath app.jar -Force
```

```bash
cd staging && zip -r ../app.jar . && cd ..
```

`Compress-Archive` writes a regular zip — fine, jars are zips. The only constraint is that the zip's entries must be at the root (e.g. `lsfusion.properties`, not `staging/lsfusion.properties`).

## Common omissions

- **Missing `lsfusion.properties`** — the platform finds modules but has no `logics.topModule`, so it doesn't know which module is the entry point. Symptom: the server starts and serves the default UI, but `:8080` shows the stock platform welcome page, not your app. Fix: put `lsfusion.properties` at the jar root with at minimum `logics.topModule = <Name>`.

- **Module path doesn't match the namespace** — e.g. `MODULE Foo.Bar;` in `something/Bar.lsf`. The platform expects directory structure to mirror namespace. If you control the source, fix the directory; if you control the module, fix the `MODULE` line.

- **Resource referenced by `.lsf` but not bundled** — `IMAGE 'logo.png'` in a module but no `logo.png` in the jar. Most modules fall back gracefully (broken image), but some fail at parse time. Always include the `src/main/resources/` tree alongside `src/main/lsfusion/` in the staging area.

- **Java action without its `.class`** — `INTERNAL com.example.MyAction()` in a `.lsf` but no `com/example/MyAction.class` in the jar. The platform parses the `.lsf` fine but throws `ClassNotFoundException` when the action runs. For from-scratch projects with Java helpers, switch to a Maven layout — there's no straightforward `javac` workflow that handles the platform classpath cleanly.

## Multi-module / multi-jar deploys

`/var/lib/lsfusion/` accepts multiple jars. The platform's classpath wildcard `/var/lib/lsfusion/*` picks them all up. Use this when:

- You have a shared "library" of common modules that several apps reuse — ship `common.jar` once, then per-app `app1.jar`, `app2.jar`.
- You need to add a third-party Java library (e.g. `tess4j-5.x.jar` for OCR) — drop it alongside your app jar.

Caveat: `lsfusion.properties` at the root of multiple jars causes one to silently win based on classpath order, which is filesystem-order-dependent. Keep `lsfusion.properties` in **one** jar to avoid surprises.

## Build artifacts that should NOT ship

When you packaged from `target/classes/`:

- `builddef.lst` — AspectJ build descriptor with absolute paths from the build host. Harmless at runtime (the platform ignores it), but it leaks `C:\Users\<name>\.m2\repository\...` info. Optional to strip.
- `generated-sources/` — AspectJ-generated Java sources from the build. Already compiled into `target/classes/<package>/*.class`; don't re-include them as a `generated-sources/` directory in the jar.
- `antrun/` — Maven antrun plugin scratch. Not needed at runtime; safe to leave or strip.

To strip the obvious ones before jarring:

```bash
rm -rf target/classes/builddef.lst target/classes/antrun
jar cf app.jar -C target/classes .
```

Not critical — the platform tolerates these — but a cleaner ship.

## Sanity-check the jar before scp

```bash
# Contents at root — should include lsfusion.properties and your top module
jar tf app.jar | head -30
# Verify lsfusion.properties is at the root (not under a subdir)
jar tf app.jar | grep -E '^lsfusion\.properties$'
# Confirm the top-module declaration — read the SOURCE you packaged
grep '^logics.topModule' target/classes/lsfusion.properties
```

(`jar tf` lists the table of contents; it does not extract sources. Don't read
entries back out of the jar — read the local source you packaged.)

If the last command returns nothing or shows the wrong module, the deploy will appear to succeed (server starts) but `:8080` will show the stock platform UI instead of your app.

To confirm what a **running** server actually loaded (rather than inspecting a jar at all), ask the server directly — `/eval/action` plus the `/files/*` source API on the web port; see the **lsfusion-eval** skill.
