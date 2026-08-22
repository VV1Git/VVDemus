import CoreGraphics

/// How many tiles Home's shortcut grid draws, and in how many columns.
///
/// Split out from `HomeView` because it is the whole of the desktop layout change and it is
/// arithmetic: a `LazyVGrid` with `.adaptive` columns decides the column count privately and
/// never tells anyone, so a grid that wants to cap itself at *two rows* has to work the count
/// out for itself and lay the columns out explicitly.
enum ShortcutGridMetrics {
    /// The widest minimum that still leaves two columns on the narrowest supported phone:
    /// 375pt less the gutters is 343, so two columns come out 165 wide. Anything larger and
    /// those phones drop to a single full-width tile.
    static let columnMinimum: CGFloat = 160

    /// The phone's share. Three rows of two — which is more rows than the desktop cap allows,
    /// deliberately: two rows of two is four tiles, and Home is the screen you reach for a
    /// thing you were just listening to.
    static let phoneCap = 6

    /// How many columns fit in `width`, given `spacing` between them.
    ///
    /// n columns need `n * minimum + (n - 1) * spacing`, so solving for n and flooring gives
    /// `(width + spacing) / (minimum + spacing)`. Never fewer than one, however narrow the
    /// window is dragged.
    static func columns(fitting width: CGFloat, spacing: CGFloat) -> Int {
        guard width > 0 else { return 1 }
        return max(1, Int((width + spacing) / (columnMinimum + spacing)))
    }

    /// How many tiles to show at `columns` wide.
    ///
    /// Two full rows on anything wide enough to have three or more columns, so the grid fills
    /// the window instead of stopping at six tiles with a third of the row empty — and stops
    /// there, so Home still leads to the shelves underneath rather than opening on a wall of
    /// tiles. Narrow windows and phones keep the six, which is fewer than two rows would be.
    static func capacity(columns: Int) -> Int {
        max(phoneCap, columns * 2)
    }

    /// The tiles that actually get drawn.
    ///
    /// On a two-column phone an odd count leaves a half-width hole at the end of the last row,
    /// so the count is trimmed to an even one — except for a lone shortcut, which would
    /// otherwise vanish from Home entirely. A wider window is left ragged on purpose: with
    /// five or six columns, trimming seven items down to five to square the grid off would
    /// hide two of them to fix a gap nobody reads as broken.
    static func visibleCount(available: Int, columns: Int) -> Int {
        let capped = min(available, capacity(columns: columns))
        guard columns == 2, capped > 1 else { return capped }
        return capped - capped % 2
    }
}
