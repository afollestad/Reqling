## Sidebar Drag And Drop

These instructions cover `Sources/Reqling/Views/Sidebar/Drag/`, the sidebar's drag after Alveary's, and the row wiring that feeds it in `Sources/Reqling/Views/Sidebar/SidebarView+Rows.swift`, `SidebarView+RowClick.swift`, and `SidebarView+ListHost.swift`. `SidebarDragController` documents the lifecycle, and `SidebarDragTargeting.swift` the zones and levels.

- **Rows take their own clicks.** Apply each row's `sidebarRowClick` before its `sidebarDragSource`, so the drag wraps the click; without that claim, the table's mouse tracking swallows the drag. Never bring back native click selection, `.draggable`, or `.dropDestination` on rows.
- **Step every row action and key handler aside while a drag is under way** (`SidebarDragController.isIdle`), or the release that ends a drag acts on the row beneath it.
- **Keep all drag geometry in `.global`, and the overlay ignoring the safe area.** A space named outside the `List` can't reach its cell-hosted rows, and an inset overlay puts the monitor's points the filter bar's height off the rows'.
- **Keep row frames out of observed state**; they change on every layout pass.
- **Keep dragging off while the sidebar is filtered**, whose shown order isn't the saved one.
