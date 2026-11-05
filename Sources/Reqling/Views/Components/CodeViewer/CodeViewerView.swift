import AppKit
import ReqlingKit

/// A read-only, virtualized text viewer for bodies of any size: the response pane's Pretty and Raw text and the body a
/// request sent.
///
/// It is laid out like an IDE's editor rather than an `NSTextView`, which holds the whole text and lays out whole
/// paragraphs, so a large body stalled scrolling and resizing and took gigabytes. Here:
///
/// - The scroll view's document view (`CodeViewerDocumentView`) draws nothing; it is only as tall as the rows,
///   `WrapLayout.rowCount` times the fixed row height, so scrolling is native and its height never changes as you
///   scroll. It takes the mouse, the keyboard, and focus.
/// - `CodeViewerCanvas` sits behind the scroll view, which draws no background, and draws only the rows in view, in
///   its own small coordinates however deep the document goes.
/// - Rows wrap at an exact column count and are colored as they are drawn (`TextHighlighter`), each built once into a
///   `CTLine` and cached (`CodeViewerView+Drawing`).
final class CodeViewerView: NSView {
    let scrollView = NSScrollView()
    let documentView = CodeViewerDocumentView()
    let canvas = CodeViewerCanvas()
    let metrics = CodeViewerMetrics.standard

    private(set) var document: TextDocument?
    /// Each line's diff style when `document` is a diff's text (`CodeViewerView+Diff`), which adds the gutter.
    private(set) var diff: [DiffLineStyle]?
    private(set) var diffGutter: DiffGutterLayout?
    private(set) var highlighter: TextHighlighter?
    private(set) var wrapLayout: WrapLayout?
    /// The selected bytes; `selectionAnchor` is the end a shift-click or drag extends from.
    var selection: Range<Int>? {
        didSet {
            if selection != oldValue {
                canvas.needsDisplay = true
            }
        }
    }
    var selectionAnchor = 0
    private(set) var matches: [Range<Int>] = []
    private(set) var currentMatch: Range<Int>?
    var accent: NSColor = .controlAccentColor {
        didSet {
            if accent != oldValue {
                canvas.needsDisplay = true
            }
        }
    }
    var onFind: ((NSTextFinder.Action) -> Void)?
    /// Rows already built, by row; cleared when the text, wrap width, or appearance changes.
    var rowCache: [Int: CodeViewerRow] = [:]
    /// The syntax palette resolved for the current appearance.
    var resolvedPalette: CodeViewerPalette?
    /// The diff colors resolved for the current appearance.
    var resolvedDiffPalette: DiffPalette?
    /// A new width arrived during a live resize while re-wrapping was too slow to repeat every frame.
    private var needsRewrap = false
    /// A byte to scroll into view once the view has a size; asked for before the first layout, it would scroll
    /// against a zero-height clip view and land wrong.
    private var pendingReveal: Int?
    /// How long the last re-wrap took, which decides whether a live resize re-wraps as it goes.
    private var lastRewrapDuration: Duration = .zero

    /// A live resize re-wraps every frame while that takes less than this, and once at its end otherwise.
    private static let liveRewrapBudget: Duration = .milliseconds(4)

    override init(frame: NSRect) {
        super.init(frame: frame)
        canvas.owner = self
        documentView.owner = self
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = documentView
        addSubview(canvas)
        addSubview(scrollView)
        // The clip view's notifications are the only signal every scroll sends: AppKit moves it with
        // `translateOrigin(to:)`, which skips an overridden `setBoundsOrigin(_:)`, and the canvas is outside the
        // scroll view, so its layer is never redrawn along with it.
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        clipView.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(clipViewDidChange(_:)), name: name, object: clipView)
        }
    }

    /// The rows in view changed: redraw them.
    @objc private func clipViewDidChange(_ notification: Notification) {
        canvas.needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        canvas.frame = scrollView.contentView.frame
        rewrapIfNeeded()
        if let pendingReveal {
            scrollToReveal(pendingReveal)
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if needsRewrap {
            rewrapIfNeeded()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolvedPalette = nil
        resolvedDiffPalette = nil
        rowCache = [:]
        canvas.needsDisplay = true
    }

    // MARK: - Content

    /// Shows `document`, from the top, with `diff`'s gutter and colors when it is a diff's text; the same document
    /// again changes nothing, as its diff comes with it.
    func setDocument(_ document: TextDocument, diff: [DiffLineStyle]? = nil) {
        guard document.id != self.document?.id else {
            return
        }
        self.document = document
        self.diff = diff
        diffGutter = diff.map(DiffGutterLayout.init(lines:))
        highlighter = TextHighlighter(document: document)
        wrapLayout = nil
        pendingReveal = nil
        selection = nil
        selectionAnchor = 0
        rowCache = [:]
        rewrapIfNeeded()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        canvas.needsDisplay = true
    }

    /// Highlights `matches`, selecting and scrolling to `current` when it changes.
    func setMatches(_ matches: [Range<Int>], current: Range<Int>?) {
        if matches != self.matches {
            self.matches = matches
            canvas.needsDisplay = true
        }
        if current != currentMatch {
            currentMatch = current
            if let current {
                selection = current
                selectionAnchor = current.lowerBound
                scrollToReveal(current.lowerBound)
            }
            canvas.needsDisplay = true
        }
    }

    // MARK: - Geometry

    /// Where each row's text starts: past the diff gutter, when there is one.
    var textInset: CGFloat {
        CodeViewerMetrics.horizontalInset + (diffGutter?.width ?? 0)
    }

    /// The columns that fit the visible width.
    private var fittingColumns: Int {
        let width = scrollView.contentView.bounds.width - textInset - CodeViewerMetrics.horizontalInset
        return max(Int(width / metrics.characterWidth), 1)
    }

    /// Re-wraps when the fitting columns changed, keeping the first visible character at the top.
    private func rewrapIfNeeded() {
        guard let document else {
            return
        }
        let columns = max(fittingColumns, TextDocument.wrapMinimumColumns)
        guard wrapLayout?.columns != columns else {
            needsRewrap = false
            documentView.frame.size.width = scrollView.contentView.bounds.width
            return
        }
        if inLiveResize, wrapLayout != nil, lastRewrapDuration > Self.liveRewrapBudget {
            needsRewrap = true
            return
        }
        needsRewrap = false
        let anchor = wrapLayout.map { topByte(in: $0) }
        let clock = ContinuousClock()
        let started = clock.now
        let newLayout = WrapLayout(document: document, columns: columns)
        lastRewrapDuration = clock.now - started
        wrapLayout = newLayout
        rowCache = [:]
        documentView.frame.size = NSSize(
            width: scrollView.contentView.bounds.width,
            height: 2 * CodeViewerMetrics.verticalInset + CGFloat(newLayout.rowCount) * metrics.rowHeight
        )
        if let anchor {
            scroll(toRowTop: newLayout.row(ofByte: anchor))
        }
        canvas.needsDisplay = true
    }

    private func topByte(in layout: WrapLayout) -> Int {
        let row = min(max(Int((scrollView.contentView.bounds.minY - CodeViewerMetrics.verticalInset) / metrics.rowHeight), 0), layout.rowCount - 1)
        return layout.byteRange(ofRow: row).lowerBound
    }

    /// The y of a row's top in the document view.
    func top(ofRow row: Int) -> CGFloat {
        CodeViewerMetrics.verticalInset + CGFloat(row) * metrics.rowHeight
    }

    /// The row at `offset` points down the document view, clamped to the rows there are.
    func row(atY offset: CGFloat) -> Int {
        let rows = wrapLayout?.rowCount ?? 1
        return min(max(Int(floor((offset - CodeViewerMetrics.verticalInset) / metrics.rowHeight)), 0), rows - 1)
    }

    private func scroll(toRowTop row: Int) {
        let clip = scrollView.contentView
        let maxY = max(documentView.frame.height - clip.bounds.height, 0)
        clip.scroll(to: NSPoint(x: 0, y: min(max(top(ofRow: row) - CodeViewerMetrics.verticalInset, 0), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Scrolls the row holding `offset` into view, centering it when it was out of sight.
    func scrollToReveal(_ offset: Int) {
        let clip = scrollView.contentView
        guard let layout = wrapLayout, clip.bounds.height > 0 else {
            pendingReveal = offset
            return
        }
        pendingReveal = nil
        let row = layout.row(ofByte: offset)
        let rowTop = top(ofRow: row)
        guard rowTop < clip.bounds.minY || rowTop + metrics.rowHeight > clip.bounds.maxY else {
            return
        }
        let maxY = max(documentView.frame.height - clip.bounds.height, 0)
        clip.scroll(to: NSPoint(x: 0, y: min(max(rowTop - clip.bounds.height / 2, 0), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Scrolls by `delta` points, clamped to the document.
    func scroll(by delta: CGFloat) {
        let clip = scrollView.contentView
        let maxY = max(documentView.frame.height - clip.bounds.height, 0)
        clip.scroll(to: NSPoint(x: 0, y: min(max(clip.bounds.minY + delta, 0), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }
}

/// The font and measurements every row shares, matching `CodeTextView`'s so a body reads the same in the editor
/// and the viewer.
struct CodeViewerMetrics {
    /// `CodeTextView`'s 6-point text container inset plus its 5-point line fragment padding.
    static let horizontalInset: CGFloat = 11
    static let verticalInset: CGFloat = 8
    @MainActor static let standard = CodeViewerMetrics(font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))

    let font: NSFont
    let rowHeight: CGFloat
    /// From a row's top to its baseline.
    let baseline: CGFloat
    let characterWidth: CGFloat

    init(font: NSFont) {
        self.font = font
        rowHeight = NSLayoutManager().defaultLineHeight(for: font)
        baseline = ((rowHeight - (font.ascender - font.descender)) / 2 + font.ascender).rounded()
        characterWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
    }
}

/// Draws the rows in view; it never takes events, which the document view above it handles.
final class CodeViewerCanvas: NSView {
    weak var owner: CodeViewerView?

    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner, let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        owner.drawRows(in: context, size: bounds.size)
    }
}
