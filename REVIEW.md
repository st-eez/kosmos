# Review scope

Changes to `Sources/KosmosApp/` and the `Sources/KosmosCore/` geometry code it
uses can change the installed window manager's behavior. They move, resize or
conceal Steve's live windows, so review runs them against the installed build. The general code classifier marked
the display position recovery Standard on 2026-10-20 and missed this production
path.
