Before changing a component, read its doc, listed in `docs/README.md`.
Comments keep only what the code can't show: macOS behavior found by probes, ordering constraints, measured costs, and a ceiling with its upgrade path, each in a line or two that points to the component doc.
Open work lives in `docs/backlog.md`: take an item out when it lands, and add new work there.
Steve permits agents to merge finished branches into `main` and to push `main` to `origin` without asking first. Build and run the tests before each.
Install Kosmos from `main` with every change committed. Install anything else only with `script/install.sh --prototype`, once Steve agrees, and tell him it is a prototype.
