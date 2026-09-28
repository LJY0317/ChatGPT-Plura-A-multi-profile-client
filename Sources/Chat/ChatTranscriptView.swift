import SwiftUI
import UIKit
import iosMath

struct ChatTranscriptView: UIViewControllerRepresentable {
    let messages: [ChatMessage]
    var onLoadEarlier: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> TranscriptViewController {
        TranscriptViewController(messages: messages, onLoadEarlier: onLoadEarlier)
    }

    func updateUIViewController(_ controller: TranscriptViewController, context: Context) {
        controller.onLoadEarlier = onLoadEarlier
        controller.update(messages: messages)
    }
}

final class TranscriptViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private let reuseIdentifier = "MessageCell"
    private let maxReadableWidth: CGFloat = 820
    private var messages: [ChatMessage]
    var onLoadEarlier: (() -> Void)?
    private var collectionView: UICollectionView!
    private var needsInitialBottomScroll = true
    private var renderCache: [UUID: RenderCacheEntry] = [:]
    private var diagnosticsLabel: UILabel?
    private var flingStartOffsetY: CGFloat = 0
    private var flingStartUptime: TimeInterval = 0
    private var flingVelocityY: CGFloat = 0
    private var flingTargetOffsetY: CGFloat = 0
    private var hasPendingFling = false
    private let requestedDecelerationRate = UIScrollView.DecelerationRate.normal.rawValue

    private var scrollDiagnosticsEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--scroll-diagnostics")
    }

    init(messages: [ChatMessage], onLoadEarlier: (() -> Void)? = nil) {
        self.messages = messages
        self.onLoadEarlier = onLoadEarlier
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 6
        layout.sectionInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        layout.estimatedItemSize = .zero

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .systemBackground
        collectionView.alwaysBounceVertical = true
        collectionView.decelerationRate = .normal
        collectionView.keyboardDismissMode = .interactive
        collectionView.accessibilityIdentifier = "chatTranscript"
        updateAccessibilityState()
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(MessageCell.self, forCellWithReuseIdentifier: reuseIdentifier)

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        if scrollDiagnosticsEnabled {
            installScrollDiagnosticsOverlay()
        }

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: TranscriptViewController, _) in
            self.renderCache.removeAll(keepingCapacity: true)
            self.collectionView.collectionViewLayout.invalidateLayout()
            self.collectionView.reloadData()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard needsInitialBottomScroll, !messages.isEmpty else { return }
        collectionView.layoutIfNeeded()
        scrollToBottom(animated: false)
        needsInitialBottomScroll = false
    }

    func update(messages newMessages: [ChatMessage]) {
        guard isViewLoaded else {
            messages = newMessages
            return
        }

        let shouldFollowBottom = isNearBottom
        let oldMessages = messages
        let oldCount = oldMessages.count
        let newCount = newMessages.count
        messages = newMessages
        updateAccessibilityState()

        if newCount == oldCount + 1,
           oldMessages.elementsEqual(newMessages.prefix(oldCount), by: { $0 == $1 }) {
            let indexPath = IndexPath(item: newCount - 1, section: 0)
            collectionView.performBatchUpdates {
                collectionView.insertItems(at: [indexPath])
            } completion: { [weak self] _ in
                guard shouldFollowBottom else { return }
                self?.scrollToBottom(animated: true)
            }
            return
        }

        if newCount == oldCount,
           newCount > 0,
           oldMessages.dropLast() == newMessages.dropLast(),
           oldMessages.last?.id == newMessages.last?.id {
            let indexPath = IndexPath(item: newCount - 1, section: 0)
            if let id = newMessages.last?.id {
                renderCache.removeValue(forKey: id)
            }
            collectionView.reconfigureItems(at: [indexPath])
            if shouldFollowBottom {
                scrollToBottom(animated: false)
            }
            return
        }

        if newCount > oldCount,
           oldMessages.elementsEqual(newMessages.suffix(oldCount), by: { $0 == $1 }) {
            let previousContentHeight = collectionView.contentSize.height
            let previousOffsetY = collectionView.contentOffset.y
            renderCache = renderCache.filter { entry in newMessages.contains(where: { $0.id == entry.key }) }
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            let addedHeight = collectionView.contentSize.height - previousContentHeight
            collectionView.contentOffset.y = previousOffsetY + addedHeight
            return
        }

        renderCache.removeAll(keepingCapacity: true)
        collectionView.reloadData()
        if shouldFollowBottom {
            collectionView.layoutIfNeeded()
            scrollToBottom(animated: false)
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        messages.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: reuseIdentifier, for: indexPath)
        guard let messageCell = cell as? MessageCell else { return cell }
        let message = messages[indexPath.item]
        let width = readableWidth(in: collectionView)
        let rendered = cachedRender(for: message, containerWidth: width)
        messageCell.configure(
            with: message,
            blocks: rendered.blocks,
            containerWidth: width
        )
        return messageCell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let width = readableWidth(in: collectionView)
        let rendered = cachedRender(for: messages[indexPath.item], containerWidth: width)
        return CGSize(
            width: width,
            height: rendered.height
        )
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        insetForSectionAt section: Int
    ) -> UIEdgeInsets {
        let horizontalInset = max(0, (collectionView.bounds.width - maxReadableWidth) / 2)
        return UIEdgeInsets(top: 12, left: horizontalInset, bottom: 12, right: horizontalInset)
    }

    private func readableWidth(in collectionView: UICollectionView) -> CGFloat {
        min(collectionView.bounds.width, maxReadableWidth)
    }

    private var isNearBottom: Bool {
        guard collectionView.contentSize.height > 0 else { return true }
        let maximumOffsetY = max(
            -collectionView.adjustedContentInset.top,
            collectionView.contentSize.height
                - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        return maximumOffsetY - collectionView.contentOffset.y <= 80
    }

    private func updateAccessibilityState() {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            collectionView.accessibilityValue = "\(messages.count)|\(messages.last?.text ?? "")"
        } else {
            collectionView.accessibilityValue = String(messages.count)
        }
    }

    private func cachedRender(for message: ChatMessage, containerWidth: CGFloat) -> RenderCacheEntry {
        let contentSizeCategory = traitCollection.preferredContentSizeCategory
        if let cached = renderCache[message.id],
           cached.message == message,
           abs(cached.containerWidth - containerWidth) < 0.5,
           cached.contentSizeCategory == contentSizeCategory {
            return cached
        }

        let markdownRender = NativeMarkdownRenderer.render(
            message.text,
            compatibleWith: traitCollection
        )
        let rendered = RenderCacheEntry(
            message: message,
            containerWidth: containerWidth,
            contentSizeCategory: contentSizeCategory,
            blocks: markdownRender.blocks,
            height: MessageCell.height(
                for: markdownRender.blocks,
                message: message,
                containerWidth: containerWidth,
                traitCollection: traitCollection
            )
        )
        renderCache[message.id] = rendered
        return rendered
    }

    private func scrollToBottom(animated: Bool) {
        guard !messages.isEmpty else { return }
        let indexPath = IndexPath(item: messages.count - 1, section: 0)
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: animated)
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard scrollDiagnosticsEnabled else { return }

        flingStartOffsetY = scrollView.contentOffset.y
        flingStartUptime = ProcessInfo.processInfo.systemUptime
        flingVelocityY = velocity.y
        flingTargetOffsetY = targetContentOffset.pointee.y
        hasPendingFling = true

        diagnosticsLabel?.text = String(
            format: "v %.2f  target Δ %.0f pt",
            velocity.y,
            targetContentOffset.pointee.y - flingStartOffsetY
        )
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollDiagnosticsEnabled, hasPendingFling else { return }
        finishScrollDiagnostics(at: scrollView.contentOffset.y, interruptedByNextDrag: true)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollDiagnosticsEnabled else { return }
        finishScrollDiagnostics(at: scrollView.contentOffset.y)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollDiagnosticsEnabled, !decelerate else { return }
        finishScrollDiagnostics(at: scrollView.contentOffset.y)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isDragging || scrollView.isDecelerating else { return }
        let top = -scrollView.adjustedContentInset.top
        if scrollView.contentOffset.y <= top + 180 {
            onLoadEarlier?()
        }
    }

    private func installScrollDiagnosticsOverlay() {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .label
        label.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.88)
        label.numberOfLines = 2
        label.layer.cornerRadius = 8
        label.layer.masksToBounds = true
        label.textAlignment = .center
        label.text = "Scroll diagnostics ready"
        label.isUserInteractionEnabled = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -24),
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: 42)
        ])

        diagnosticsLabel = label
    }

    private func finishScrollDiagnostics(at finalOffsetY: CGFloat, interruptedByNextDrag: Bool = false) {
        guard hasPendingFling else { return }
        hasPendingFling = false

        let duration = max(0, ProcessInfo.processInfo.systemUptime - flingStartUptime)
        let actualDistance = finalOffsetY - flingStartOffsetY
        let targetDistance = flingTargetOffsetY - flingStartOffsetY
        let minimumOffsetY = -collectionView.adjustedContentInset.top
        let maximumOffsetY = max(
            minimumOffsetY,
            collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom
        )
        let hitBoundary = finalOffsetY <= minimumOffsetY + 1 || finalOffsetY >= maximumOffsetY - 1

        guard abs(flingVelocityY) >= 0.05, abs(targetDistance) >= 1 else {
            diagnosticsLabel?.text = "Ignored non-fling scroll event"
            return
        }

        persistScrollDiagnostics(
            ScrollDiagnosticsSample(
                timestamp: Date(),
                velocityY: flingVelocityY,
                startOffsetY: flingStartOffsetY,
                targetOffsetY: flingTargetOffsetY,
                finalOffsetY: finalOffsetY,
                targetDistanceY: targetDistance,
                actualDistanceY: actualDistance,
                duration: duration,
                decelerationRate: collectionView.decelerationRate.rawValue,
                requestedDecelerationRate: requestedDecelerationRate,
                hitBoundary: hitBoundary,
                interruptedByNextDrag: interruptedByNextDrag
            )
        )

        diagnosticsLabel?.text = String(
            format: "v %.2f  actual Δ %.0f pt\n%.2f s  target Δ %.0f pt",
            flingVelocityY,
            actualDistance,
            duration,
            targetDistance
        )

        print(
            String(
                format: "SCROLL_DIAGNOSTICS velocityY=%.3f actualDistanceY=%.1f duration=%.3f targetDistanceY=%.1f",
                flingVelocityY,
                actualDistance,
                duration,
                targetDistance
            )
        )
    }

    private func persistScrollDiagnostics(_ sample: ScrollDiagnosticsSample) {
        do {
            let documentsURL = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let fileURL = documentsURL.appendingPathComponent("scroll-diagnostics.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var samples: [ScrollDiagnosticsSample] = []

            if let existingData = try? Data(contentsOf: fileURL) {
                if let existingSamples = try? decoder.decode([ScrollDiagnosticsSample].self, from: existingData) {
                    samples = existingSamples
                } else if let existingSample = try? decoder.decode(ScrollDiagnosticsSample.self, from: existingData) {
                    samples = [existingSample]
                }
            }

            samples.append(sample)
            if samples.count > 32 {
                samples.removeFirst(samples.count - 32)
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(samples).write(to: fileURL, options: .atomic)
        } catch {
            print("SCROLL_DIAGNOSTICS_WRITE_FAILED \(error)")
        }
    }
}

private struct ScrollDiagnosticsSample: Codable {
    let timestamp: Date
    let velocityY: CGFloat
    let startOffsetY: CGFloat
    let targetOffsetY: CGFloat
    let finalOffsetY: CGFloat
    let targetDistanceY: CGFloat
    let actualDistanceY: CGFloat
    let duration: TimeInterval
    let decelerationRate: CGFloat
    let requestedDecelerationRate: CGFloat?
    let hitBoundary: Bool?
    let interruptedByNextDrag: Bool?
}

private struct RenderCacheEntry {
    let message: ChatMessage
    let containerWidth: CGFloat
    let contentSizeCategory: UIContentSizeCategory
    let blocks: [NativeMarkdownRenderer.RenderedBlock]
    let height: CGFloat
}

private struct MarkdownImage: Equatable {
    let url: URL
    let altText: String
}

private struct MarkdownMath: Equatable {
    let latex: String
}

private struct MarkdownCodeBlock {
    let language: String?
    let code: String
    let attributedCode: NSAttributedString
}

private struct MarkdownTable {
    let rows: [[String]]

    var columnCount: Int {
        rows.map(\.count).max() ?? 0
    }
}

private final class MessageCell: UICollectionViewCell {
    private static let horizontalBubbleRatio: CGFloat = 0.86
    private static let horizontalTextInset: CGFloat = 14
    private static let verticalTextInset: CGFloat = 10
    private static let verticalCellInset: CGFloat = 3
    private static let imagePreviewHeight: CGFloat = 180
    private static let contentSpacing: CGFloat = 8

    private let bubble = UIView()
    private let contentStack = UIStackView()
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!
    private var userMaxWidthConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)

        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.layer.cornerRadius = 18
        bubble.layer.cornerCurve = .continuous

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = Self.contentSpacing

        contentView.addSubview(bubble)
        bubble.addSubview(contentStack)

        leadingConstraint = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14)
        trailingConstraint = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14)
        userMaxWidthConstraint = bubble.widthAnchor.constraint(
            lessThanOrEqualTo: contentView.widthAnchor,
            multiplier: Self.horizontalBubbleRatio
        )

        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),

            contentStack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
            contentStack.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            contentStack.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        removeRenderedViews()
    }

    func configure(
        with message: ChatMessage,
        blocks: [NativeMarkdownRenderer.RenderedBlock],
        containerWidth: CGFloat
    ) {
        removeRenderedViews()
        let bubbleWidth = Self.contentWidth(for: message.role, containerWidth: containerWidth)
        let contentWidth = max(0, bubbleWidth - (Self.horizontalTextInset * 2))

        if message.role == .activity {
            let height = SemanticActivityCardView.height(
                for: message,
                blocks: blocks,
                contentWidth: contentWidth,
                traitCollection: traitCollection
            )
            let card = SemanticActivityCardView(height: height)
            card.configure(with: message, blocks: blocks, contentWidth: contentWidth)
            contentStack.addArrangedSubview(card)
        } else {
            for block in blocks {
                switch block {
                case .text(let attributedText):
                    let label = InteractiveLabel()
                    label.translatesAutoresizingMaskIntoConstraints = false
                    label.numberOfLines = 0
                    label.adjustsFontForContentSizeCategory = true
                    label.attributedText = attributedText
                    label.isAccessibilityElement = true
                    label.accessibilityLabel = attributedText.string
                    contentStack.addArrangedSubview(label)
                case .code(let code):
                    let height = NativeCodeBlockView.height(
                        for: code,
                        contentWidth: contentWidth
                    )
                    let codeView = NativeCodeBlockView(height: height)
                    codeView.configure(with: code)
                    contentStack.addArrangedSubview(codeView)
                case .image(let image):
                    let imageView = RemoteMarkdownImageView(previewHeight: Self.imagePreviewHeight)
                    imageView.configure(with: image)
                    contentStack.addArrangedSubview(imageView)
                case .math(let math):
                    let mathHeight = NativeMathView.height(compatibleWith: traitCollection)
                    let mathView = NativeMathView(previewHeight: mathHeight, compatibleWith: traitCollection)
                    mathView.configure(with: math)
                    contentStack.addArrangedSubview(mathView)
                case .table(let table):
                    let height = NativeTableBlockView.height(for: table, compatibleWith: traitCollection)
                    let tableView = NativeTableBlockView(height: height)
                    tableView.configure(with: table)
                    contentStack.addArrangedSubview(tableView)
                }
            }
        }

        switch message.role {
        case .user:
            leadingConstraint.isActive = false
            trailingConstraint.isActive = true
            userMaxWidthConstraint.isActive = true
            bubble.backgroundColor = .secondarySystemBackground

        case .assistant:
            leadingConstraint.isActive = true
            trailingConstraint.isActive = true
            userMaxWidthConstraint.isActive = false
            bubble.backgroundColor = .clear

        case .activity:
            leadingConstraint.isActive = true
            trailingConstraint.isActive = true
            userMaxWidthConstraint.isActive = false
            bubble.backgroundColor = .clear
        }
    }

    private func removeRenderedViews() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    static func height(
        for blocks: [NativeMarkdownRenderer.RenderedBlock],
        message: ChatMessage,
        containerWidth: CGFloat,
        traitCollection: UITraitCollection
    ) -> CGFloat {
        let bubbleWidth = contentWidth(for: message.role, containerWidth: containerWidth)
        let textWidth = max(0, bubbleWidth - (horizontalTextInset * 2))
        if message.role == .activity {
            let cardHeight = SemanticActivityCardView.height(
                for: message,
                blocks: blocks,
                contentWidth: textWidth,
                traitCollection: traitCollection
            )
            return cardHeight + (verticalTextInset * 2) + (verticalCellInset * 2)
        }
        var contentHeight: CGFloat = 0
        for block in blocks {
            switch block {
            case .text(let attributedText):
                let bounds = attributedText.boundingRect(
                    with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
                contentHeight += ceil(bounds.height)
            case .code(let code):
                contentHeight += NativeCodeBlockView.height(
                    for: code,
                    contentWidth: textWidth
                )
            case .image:
                contentHeight += imagePreviewHeight
            case .math:
                contentHeight += NativeMathView.height(compatibleWith: traitCollection)
            case .table(let table):
                contentHeight += NativeTableBlockView.height(for: table, compatibleWith: traitCollection)
            }
        }
        let spacingHeight = CGFloat(max(0, blocks.count - 1)) * contentSpacing
        return contentHeight + spacingHeight + (verticalTextInset * 2) + (verticalCellInset * 2)
    }

    private static func contentWidth(for role: ChatMessage.Role, containerWidth: CGFloat) -> CGFloat {
        switch role {
        case .user:
            containerWidth * horizontalBubbleRatio
        case .assistant, .activity:
            max(0, containerWidth - 28)
        }
    }
}

private final class SemanticActivityCardView: UIView {
    private static let cardPadding: CGFloat = 12
    private static let contentSpacing: CGFloat = 8
    private static let headerSpacing: CGFloat = 8
    private static let iconSize: CGFloat = 19
    private static let imagePreviewHeight: CGFloat = 180

    private let stack = UIStackView()

    init(height: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1 / UIScreen.main.scale
        layer.borderColor = UIColor.separator.cgColor
        clipsToBounds = true

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Self.contentSpacing
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.cardPadding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.cardPadding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.cardPadding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.cardPadding)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        with message: ChatMessage,
        blocks: [NativeMarkdownRenderer.RenderedBlock],
        contentWidth: CGFloat
    ) {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let title = Self.presentationTitle(for: message)
        let header = UIStackView()
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = Self.headerSpacing

        let icon = UIImageView(image: UIImage(systemName: Self.systemImageName(for: message.kind)))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.isAccessibilityElement = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize)
        ])
        header.addArrangedSubview(icon)

        let titleLabel = UILabel()
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.font = Self.titleFont(compatibleWith: traitCollection)
        titleLabel.text = title
        titleLabel.accessibilityIdentifier = "activityCard.\(message.kind.rawValue).title"
        header.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(header)

        if let metadata = Self.metadataText(for: message) {
            let metadataLabel = UILabel()
            metadataLabel.numberOfLines = 2
            metadataLabel.adjustsFontForContentSizeCategory = true
            metadataLabel.font = .preferredFont(forTextStyle: .caption1)
            metadataLabel.textColor = .secondaryLabel
            metadataLabel.text = metadata
            metadataLabel.accessibilityIdentifier = "activityCard.\(message.kind.rawValue).metadata"
            stack.addArrangedSubview(metadataLabel)
        }

        let bodyWidth = max(1, contentWidth - (Self.cardPadding * 2))
        for block in blocks {
            switch block {
            case .text(let attributedText):
                let label = InteractiveLabel()
                label.translatesAutoresizingMaskIntoConstraints = false
                label.numberOfLines = 0
                label.adjustsFontForContentSizeCategory = true
                label.attributedText = attributedText
                label.isAccessibilityElement = true
                label.accessibilityLabel = attributedText.string
                label.accessibilityIdentifier = "activityCard.\(message.kind.rawValue).detail"
                stack.addArrangedSubview(label)
            case .code(let code):
                let codeView = NativeCodeBlockView(
                    height: NativeCodeBlockView.height(for: code, contentWidth: bodyWidth)
                )
                codeView.configure(with: code)
                stack.addArrangedSubview(codeView)
            case .image(let image):
                let imageView = RemoteMarkdownImageView(previewHeight: Self.imagePreviewHeight)
                imageView.configure(with: image)
                stack.addArrangedSubview(imageView)
            case .math(let math):
                let mathHeight = NativeMathView.height(compatibleWith: traitCollection)
                let mathView = NativeMathView(previewHeight: mathHeight, compatibleWith: traitCollection)
                mathView.configure(with: math)
                stack.addArrangedSubview(mathView)
            case .table(let table):
                let tableView = NativeTableBlockView(
                    height: NativeTableBlockView.height(for: table, compatibleWith: traitCollection)
                )
                tableView.configure(with: table)
                stack.addArrangedSubview(tableView)
            }
        }

        accessibilityIdentifier = "activityCard.\(message.kind.rawValue)"
    }

    static func height(
        for message: ChatMessage,
        blocks: [NativeMarkdownRenderer.RenderedBlock],
        contentWidth: CGFloat,
        traitCollection: UITraitCollection
    ) -> CGFloat {
        let innerWidth = max(1, contentWidth - (cardPadding * 2))
        let titleWidth = max(1, innerWidth - iconSize - headerSpacing)
        let title = presentationTitle(for: message) as NSString
        let titleBounds = title.boundingRect(
            with: CGSize(width: titleWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: titleFont(compatibleWith: traitCollection)],
            context: nil
        )
        let headerHeight = max(iconSize, ceil(titleBounds.height))

        var contentHeight = headerHeight
        var arrangedCount = 1
        if let metadata = metadataText(for: message) {
            let font = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traitCollection)
            let bounds = (metadata as NSString).boundingRect(
                with: CGSize(width: innerWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )
            contentHeight += ceil(bounds.height)
            arrangedCount += 1
        }

        for block in blocks {
            switch block {
            case .text(let attributedText):
                let bounds = attributedText.boundingRect(
                    with: CGSize(width: innerWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
                contentHeight += ceil(bounds.height)
            case .code(let code):
                contentHeight += NativeCodeBlockView.height(for: code, contentWidth: innerWidth)
            case .image:
                contentHeight += imagePreviewHeight
            case .math:
                contentHeight += NativeMathView.height(compatibleWith: traitCollection)
            case .table(let table):
                contentHeight += NativeTableBlockView.height(for: table, compatibleWith: traitCollection)
            }
            arrangedCount += 1
        }

        contentHeight += CGFloat(max(0, arrangedCount - 1)) * contentSpacing
        return ceil(contentHeight + (cardPadding * 2))
    }

    private static func titleFont(compatibleWith traitCollection: UITraitCollection) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traitCollection)
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    private static func presentationTitle(for message: ChatMessage) -> String {
        if let title = message.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return switch message.kind {
        case .message: "Message"
        case .reasoningSummary: "Thinking"
        case .toolCall: "Tool"
        case .commandExecution: "Command"
        case .fileChange: "File changes"
        case .webSearch: "Web search"
        case .imageView: "Image viewed"
        case .approval: "Approval"
        case .attachment: "Attachment"
        case .notice, .unknown: "Activity"
        }
    }

    private static func systemImageName(for kind: ChatMessage.Kind) -> String {
        switch kind {
        case .message: "bubble.left"
        case .reasoningSummary: "sparkles"
        case .toolCall: "wrench.and.screwdriver"
        case .commandExecution: "terminal"
        case .fileChange: "doc.text"
        case .webSearch: "globe"
        case .imageView: "photo"
        case .approval: "checkmark.shield"
        case .attachment: "paperclip"
        case .notice: "info.circle"
        case .unknown: "square.dashed"
        }
    }

    private static func metadataText(for message: ChatMessage) -> String? {
        var values: [String] = []
        if let status = message.status?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty {
            values.append(status)
        }
        if let duration = message.durationMilliseconds, duration >= 0 {
            let seconds = Double(duration) / 1_000
            values.append(String(format: seconds < 10 ? "%.1fs" : "%.0fs", seconds))
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }
}

private final class NativeTableBlockView: UIScrollView {
    private static let maximumVisibleRows = 7
    private static let cellWidth: CGFloat = 132

    private let rowsStack = UIStackView()

    init(height: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.borderWidth = 1 / UIScreen.main.scale
        layer.borderColor = UIColor.separator.cgColor
        clipsToBounds = true
        showsHorizontalScrollIndicator = true
        showsVerticalScrollIndicator = true
        accessibilityIdentifier = "tableBlock"

        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.axis = .vertical
        rowsStack.alignment = .fill
        rowsStack.distribution = .fill
        rowsStack.spacing = 0
        addSubview(rowsStack)

        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with table: MarkdownTable) {
        rowsStack.arrangedSubviews.forEach { view in
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let columns = max(1, table.columnCount)
        for (rowIndex, row) in table.rows.enumerated() {
            let rowStack = UIStackView()
            rowStack.translatesAutoresizingMaskIntoConstraints = false
            rowStack.axis = .horizontal
            rowStack.alignment = .fill
            rowStack.distribution = .fill
            rowStack.spacing = 0
            rowStack.heightAnchor.constraint(
                equalToConstant: Self.rowHeight(compatibleWith: traitCollection)
            ).isActive = true

            for columnIndex in 0..<columns {
                let label = UILabel()
                label.translatesAutoresizingMaskIntoConstraints = false
                label.numberOfLines = 2
                label.adjustsFontForContentSizeCategory = true
                let baseFont = UIFont.preferredFont(forTextStyle: .subheadline)
                if rowIndex == 0,
                   let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitBold) {
                    label.font = UIFont(descriptor: descriptor, size: baseFont.pointSize)
                } else {
                    label.font = baseFont
                }
                label.textColor = .label
                label.text = columnIndex < row.count ? row[columnIndex] : ""
                label.backgroundColor = rowIndex == 0 ? .tertiarySystemFill : .systemBackground
                label.layer.borderWidth = 0.5 / UIScreen.main.scale
                label.layer.borderColor = UIColor.separator.cgColor
                label.widthAnchor.constraint(equalToConstant: Self.cellWidth).isActive = true
                label.setContentCompressionResistancePriority(.required, for: .horizontal)
                label.accessibilityIdentifier = rowIndex == 0 ? "tableBlock.header" : "tableBlock.cell"

                let inset = UIEdgeInsets(top: 6, left: 9, bottom: 6, right: 9)
                let container = InsetLabelContainer(label: label, insets: inset)
                rowStack.addArrangedSubview(container)
            }
            rowsStack.addArrangedSubview(rowStack)
        }
    }

    static func height(for table: MarkdownTable, compatibleWith traitCollection: UITraitCollection) -> CGFloat {
        let visibleRows = min(max(1, table.rows.count), maximumVisibleRows)
        return CGFloat(visibleRows) * rowHeight(compatibleWith: traitCollection)
    }

    private static func rowHeight(compatibleWith traitCollection: UITraitCollection) -> CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traitCollection)
        return max(42, ceil(font.lineHeight * 2 + 12))
    }
}

private final class InsetLabelContainer: UIView {
    init(label: UILabel, insets: UIEdgeInsets) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = label.backgroundColor
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            label.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class NativeCodeBlockView: UIView {
    private static let headerHeight: CGFloat = 34
    private static let maximumBodyHeight: CGFloat = 360
    private static let bodyInset: CGFloat = 10

    private let languageLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let textView = UITextView()
    private var rawCode = ""

    init(height: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true

        languageLabel.translatesAutoresizingMaskIntoConstraints = false
        languageLabel.font = .preferredFont(forTextStyle: .caption1)
        languageLabel.textColor = .secondaryLabel
        languageLabel.adjustsFontForContentSizeCategory = true
        languageLabel.isAccessibilityElement = true
        languageLabel.accessibilityIdentifier = "codeBlock.language"

        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "doc.on.doc")
        configuration.title = "Copy"
        configuration.imagePadding = 5
        configuration.contentInsets = .zero
        copyButton.configuration = configuration
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        copyButton.addTarget(self, action: #selector(copyCode), for: .touchUpInside)
        copyButton.accessibilityIdentifier = "codeBlock.copy"

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = false
        textView.textContainerInset = UIEdgeInsets(
            top: Self.bodyInset,
            left: Self.bodyInset,
            bottom: Self.bodyInset,
            right: Self.bodyInset
        )
        textView.textContainer.lineFragmentPadding = 0

        addSubview(languageLabel)
        addSubview(copyButton)
        addSubview(textView)

        NSLayoutConstraint.activate([
            languageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            languageLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.headerHeight / 2),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            copyButton.centerYAnchor.constraint(equalTo: languageLabel.centerYAnchor),
            copyButton.leadingAnchor.constraint(greaterThanOrEqualTo: languageLabel.trailingAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor, constant: Self.headerHeight),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with code: MarkdownCodeBlock) {
        rawCode = code.code
        languageLabel.text = code.language?.uppercased() ?? "CODE"
        languageLabel.accessibilityLabel = languageLabel.text
        textView.attributedText = code.attributedCode
        textView.accessibilityLabel = code.code
        accessibilityLabel = code.language.map { "\($0) code block" } ?? "Code block"
        accessibilityIdentifier = "codeBlock"
    }

    @objc private func copyCode() {
        UIPasteboard.general.string = rawCode
        copyButton.configuration?.image = UIImage(systemName: "checkmark")
        copyButton.configuration?.title = "Copied"
    }

    static func height(
        for code: MarkdownCodeBlock,
        contentWidth: CGFloat
    ) -> CGFloat {
        let bodyWidth = max(1, contentWidth - (bodyInset * 2))
        let bounds = code.attributedCode.boundingRect(
            with: CGSize(width: bodyWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let bodyHeight = min(max(54, ceil(bounds.height) + (bodyInset * 2)), maximumBodyHeight)
        return headerHeight + bodyHeight
    }
}

private final class NativeMathView: UIView {
    private let mathLabel = MTMathUILabel()

    init(previewHeight: CGFloat, compatibleWith traitCollection: UITraitCollection) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: previewHeight).isActive = true

        mathLabel.translatesAutoresizingMaskIntoConstraints = false
        mathLabel.fontSize = UIFont.preferredFont(
            forTextStyle: .title3,
            compatibleWith: traitCollection
        ).pointSize
        mathLabel.textColor = .label
        mathLabel.textAlignment = .center
        mathLabel.mode = .display
        addSubview(mathLabel)

        NSLayoutConstraint.activate([
            mathLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            mathLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            mathLabel.topAnchor.constraint(equalTo: topAnchor),
            mathLabel.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with math: MarkdownMath) {
        mathLabel.latex = math.latex
        accessibilityLabel = math.latex
        isAccessibilityElement = true
    }

    static func height(compatibleWith traitCollection: UITraitCollection) -> CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .title3, compatibleWith: traitCollection)
        return max(72, ceil(font.lineHeight * 2.4))
    }
}

private final class RemoteMarkdownImageView: UIImageView {
    private var representedURL: URL?
    private var loadTask: Task<Void, Never>?

    init(previewHeight: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        contentMode = .scaleAspectFit
        clipsToBounds = true
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        backgroundColor = .secondarySystemBackground
        tintColor = .secondaryLabel
        isAccessibilityElement = true
        heightAnchor.constraint(equalToConstant: previewHeight).isActive = true
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 260, height: 180)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTask?.cancel()
    }

    func configure(with image: MarkdownImage) {
        loadTask?.cancel()
        representedURL = image.url
        accessibilityLabel = image.altText.isEmpty ? "Image" : image.altText
        self.image = UIImage(systemName: "photo")

        loadTask = Task { @MainActor [weak self] in
            let loadedImage = await RemoteImageLoader.shared.image(for: image.url)
            guard !Task.isCancelled,
                  let self,
                  self.representedURL == image.url,
                  let loadedImage else { return }
            self.image = loadedImage
        }
    }
}

@MainActor
private final class RemoteImageLoader {
    static let shared = RemoteImageLoader()

    private let cache = NSCache<NSURL, UIImage>()
    private let maximumImageBytes = 20 * 1_024 * 1_024

    private init() {
        cache.countLimit = 80
    }

    func image(for url: URL) async -> UIImage? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }

        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              !Task.isCancelled,
              let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              httpResponse.mimeType?.lowercased().hasPrefix("image/") == true,
              data.count <= maximumImageBytes,
              let image = UIImage(data: data) else { return nil }

        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

private final class InteractiveLabel: UILabel {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc
    private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let attributedText,
              attributedText.length > 0 else { return }

        let textStorage = NSTextStorage(attributedString: attributedText)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: bounds.size)
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = numberOfLines
        textContainer.lineBreakMode = lineBreakMode
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let usedRect = layoutManager.usedRect(for: textContainer)
        let horizontalOffset: CGFloat
        switch textAlignment {
        case .center:
            horizontalOffset = (bounds.width - usedRect.width) / 2 - usedRect.minX
        case .right:
            horizontalOffset = bounds.width - usedRect.width - usedRect.minX
        default:
            horizontalOffset = -usedRect.minX
        }
        let verticalOffset = (bounds.height - usedRect.height) / 2 - usedRect.minY
        let location = recognizer.location(in: self)
        let textPoint = CGPoint(
            x: location.x - horizontalOffset,
            y: location.y - verticalOffset
        )

        guard textPoint.x >= 0,
              textPoint.y >= 0,
              textPoint.x <= textContainer.size.width,
              textPoint.y <= textContainer.size.height else { return }

        let glyphIndex = layoutManager.glyphIndex(for: textPoint, in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < attributedText.length else { return }

        var linkRange = NSRange(location: 0, length: 0)
        guard let url = attributedText.attribute(
            .link,
            at: characterIndex,
            effectiveRange: &linkRange
        ) as? URL else { return }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: linkRange, actualCharacterRange: nil)
        guard layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer).contains(textPoint),
              isAllowedLink(url) else { return }

        UIApplication.shared.open(url)
    }

    private func isAllowedLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }
}

private enum NativeMarkdownRenderer {
    struct RenderedMarkdown {
        let blocks: [RenderedBlock]
    }

    enum RenderedBlock {
        case text(NSAttributedString)
        case code(MarkdownCodeBlock)
        case image(MarkdownImage)
        case math(MarkdownMath)
        case table(MarkdownTable)
    }

    private struct InlineStyle: OptionSet {
        let rawValue: Int

        static let bold = InlineStyle(rawValue: 1 << 0)
        static let italic = InlineStyle(rawValue: 1 << 1)
        static let code = InlineStyle(rawValue: 1 << 2)
    }

    static func render(_ markdown: String, compatibleWith traitCollection: UITraitCollection) -> RenderedMarkdown {
        var textOutput = NSMutableAttributedString()
        var blocks: [RenderedBlock] = []
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var inCodeBlock = false
        var codeLines: [String] = []
        var codeLanguage: String?
        var codeFenceLength = 0
        var inMathBlock = false
        var mathLines: [String] = []
        var tableSkipThroughIndex = -1

        func flushText() {
            while textOutput.length > 0, textOutput.string.hasSuffix("\n") {
                textOutput.deleteCharacters(in: NSRange(location: textOutput.length - 1, length: 1))
            }
            guard textOutput.length > 0 else { return }
            blocks.append(.text(NSAttributedString(attributedString: textOutput)))
            textOutput = NSMutableAttributedString()
        }

        func fenceInfo(_ line: String) -> (length: Int, suffix: Substring)? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var length = 0
            var index = trimmed.startIndex
            while index < trimmed.endIndex, trimmed[index] == "`" {
                length += 1
                index = trimmed.index(after: index)
            }
            guard length >= 3 else { return nil }
            return (length, trimmed[index...])
        }

        for (index, line) in lines.enumerated() {
            if index <= tableSkipThroughIndex {
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = fenceInfo(line), !inMathBlock {
                if inCodeBlock {
                    if fence.length >= codeFenceLength,
                       fence.suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        flushText()
                        blocks.append(.code(renderCodeBlock(
                            codeLines.joined(separator: "\n"),
                            language: codeLanguage,
                            traitCollection: traitCollection
                        )))
                        codeLines.removeAll(keepingCapacity: true)
                        codeLanguage = nil
                        codeFenceLength = 0
                        inCodeBlock = false
                    } else {
                        codeLines.append(line)
                    }
                } else {
                    flushText()
                    let language = fence.suffix.trimmingCharacters(in: .whitespacesAndNewlines)
                    codeLanguage = language.isEmpty ? nil : normalizedCodeLanguage(language)
                    codeFenceLength = fence.length
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeLines.append(line)
                continue
            }

            if !inMathBlock,
               index + 1 < lines.count,
               let header = parseTableRow(line),
               let separator = parseTableRow(lines[index + 1]),
               isTableSeparatorRow(separator),
               header.count == separator.count,
               !header.isEmpty {
                flushText()
                var rows = [header]
                var nextIndex = index + 2
                while nextIndex < lines.count,
                      let row = parseTableRow(lines[nextIndex]),
                      !row.isEmpty {
                    rows.append(row)
                    nextIndex += 1
                }
                blocks.append(.table(MarkdownTable(rows: rows)))
                tableSkipThroughIndex = max(index + 1, nextIndex - 1)
                continue
            }

            if trimmed == "$$" {
                if inMathBlock {
                    let latex = mathLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !latex.isEmpty {
                        blocks.append(.math(MarkdownMath(latex: latex)))
                    }
                    mathLines.removeAll(keepingCapacity: true)
                    inMathBlock = false
                } else {
                    flushText()
                    inMathBlock = true
                }
                continue
            }

            if inMathBlock {
                mathLines.append(line)
                continue
            }

            if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 {
                let start = trimmed.index(trimmed.startIndex, offsetBy: 2)
                let end = trimmed.index(trimmed.endIndex, offsetBy: -2)
                let latex = trimmed[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
                if !latex.isEmpty {
                    flushText()
                    blocks.append(.math(MarkdownMath(latex: latex)))
                }
                continue
            }

            if let image = parseImageLine(trimmed) {
                flushText()
                blocks.append(.image(image))
                continue
            }

            if let heading = parseHeading(line) {
                appendHeading(heading, to: textOutput, traitCollection: traitCollection)
            } else if let quote = parseBlockquote(line) {
                appendBlockquote(quote, to: textOutput, traitCollection: traitCollection)
            } else if let listItem = parseListItem(line) {
                appendListItem(listItem, to: textOutput, traitCollection: traitCollection)
            } else {
                appendInlineMarkdown(line, to: textOutput, traitCollection: traitCollection)
            }

            if index < lines.count - 1 {
                textOutput.append(NSAttributedString(string: "\n"))
            }
        }

        if inCodeBlock {
            flushText()
            blocks.append(.code(renderCodeBlock(
                codeLines.joined(separator: "\n"),
                language: codeLanguage,
                traitCollection: traitCollection
            )))
        }

        if inMathBlock {
            appendInlineMarkdown("$$", to: textOutput, traitCollection: traitCollection)
            if !mathLines.isEmpty {
                textOutput.append(NSAttributedString(string: "\n"))
                appendInlineMarkdown(mathLines.joined(separator: "\n"), to: textOutput, traitCollection: traitCollection)
            }
        }

        flushText()
        return RenderedMarkdown(blocks: blocks)
    }

    private static func parseTableRow(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        var source = trimmed
        if source.first == "|" { source.removeFirst() }
        if source.last == "|" { source.removeLast() }
        guard !source.isEmpty else { return nil }

        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in source {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func isTableSeparatorRow(_ cells: [String]) -> Bool {
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { value in
            var marker = value.trimmingCharacters(in: .whitespaces)
            if marker.first == ":" { marker.removeFirst() }
            if marker.last == ":" { marker.removeLast() }
            return marker.count >= 3 && marker.allSatisfy { $0 == "-" }
        }
    }

    private static func parseImageLine(_ line: String) -> MarkdownImage? {
        guard line.hasPrefix("!["), line.hasSuffix(")") else { return nil }
        let altStart = line.index(line.startIndex, offsetBy: 2)
        guard let separator = line.range(of: "](", range: altStart..<line.endIndex) else { return nil }

        let destinationEnd = line.index(before: line.endIndex)
        guard separator.upperBound <= destinationEnd else { return nil }

        let altText = String(line[altStart..<separator.lowerBound])
        let destination = String(line[separator.upperBound..<destinationEnd])
        guard let url = safeLinkURL(destination) else { return nil }
        return MarkdownImage(url: url, altText: altText)
    }

    private static func appendInlineMarkdown(
        _ text: String,
        to output: NSMutableAttributedString,
        traitCollection: UITraitCollection,
        paragraphStyle: NSParagraphStyle? = nil
    ) {
        var cursor = text.startIndex
        var plainStart = cursor

        func flushPlain(until end: String.Index) {
            guard plainStart < end else { return }
            append(
                String(text[plainStart..<end]),
                style: [],
                to: output,
                traitCollection: traitCollection,
                paragraphStyle: paragraphStyle
            )
        }

        while cursor < text.endIndex {
            if text[cursor...].hasPrefix("`") {
                let contentStart = text.index(after: cursor)
                if let closing = text[contentStart...].firstIndex(of: "`") {
                    flushPlain(until: cursor)
                    append(
                        String(text[contentStart..<closing]),
                        style: .code,
                        to: output,
                        traitCollection: traitCollection,
                        paragraphStyle: paragraphStyle
                    )
                    cursor = text.index(after: closing)
                    plainStart = cursor
                    continue
                }
            }

            if text[cursor...].hasPrefix("[") {
                let labelStart = text.index(after: cursor)
                if let labelEnd = text[labelStart...].firstIndex(of: "]") {
                    let openParen = text.index(after: labelEnd)
                    if openParen < text.endIndex, text[openParen] == "(" {
                        let destinationStart = text.index(after: openParen)
                        if let destinationEnd = text[destinationStart...].firstIndex(of: ")") {
                            let destination = String(text[destinationStart..<destinationEnd])
                            if let url = safeLinkURL(destination) {
                                flushPlain(until: cursor)
                                append(
                                    String(text[labelStart..<labelEnd]),
                                    style: [],
                                    to: output,
                                    traitCollection: traitCollection,
                                    paragraphStyle: paragraphStyle,
                                    link: url
                                )
                                cursor = text.index(after: destinationEnd)
                                plainStart = cursor
                                continue
                            }
                        }
                    }
                }
            }

            if text[cursor...].hasPrefix("**") {
                let contentStart = text.index(cursor, offsetBy: 2)
                if let closing = text.range(of: "**", range: contentStart..<text.endIndex)?.lowerBound {
                    flushPlain(until: cursor)
                    append(
                        String(text[contentStart..<closing]),
                        style: .bold,
                        to: output,
                        traitCollection: traitCollection,
                        paragraphStyle: paragraphStyle
                    )
                    cursor = text.index(closing, offsetBy: 2)
                    plainStart = cursor
                    continue
                }
            }

            if text[cursor...].hasPrefix("*") {
                let contentStart = text.index(after: cursor)
                if let closing = text[contentStart...].firstIndex(of: "*") {
                    flushPlain(until: cursor)
                    append(
                        String(text[contentStart..<closing]),
                        style: .italic,
                        to: output,
                        traitCollection: traitCollection,
                        paragraphStyle: paragraphStyle
                    )
                    cursor = text.index(after: closing)
                    plainStart = cursor
                    continue
                }
            }

            cursor = text.index(after: cursor)
        }

        flushPlain(until: text.endIndex)
    }

    private static func append(
        _ text: String,
        style: InlineStyle,
        to output: NSMutableAttributedString,
        traitCollection: UITraitCollection,
        paragraphStyle: NSParagraphStyle?,
        link: URL? = nil
    ) {
        guard !text.isEmpty else { return }

        let bodyFont = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        var font = bodyFont

        if style.contains(.code) {
            font = UIFont.monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular)
        } else {
            var traits: UIFontDescriptor.SymbolicTraits = []
            if style.contains(.bold) { traits.insert(.traitBold) }
            if style.contains(.italic) { traits.insert(.traitItalic) }
            if !traits.isEmpty, let descriptor = bodyFont.fontDescriptor.withSymbolicTraits(traits) {
                font = UIFont(descriptor: descriptor, size: bodyFont.pointSize)
            }
        }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.label
        ]

        if style.contains(.code) {
            attributes[.backgroundColor] = UIColor.secondarySystemBackground
        }
        if let paragraphStyle {
            attributes[.paragraphStyle] = paragraphStyle
        }
        if let link {
            attributes[.link] = link
            attributes[.foregroundColor] = UIColor.link
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        output.append(NSAttributedString(string: text, attributes: attributes))
    }

    private static func safeLinkURL(_ destination: String) -> URL? {
        guard let url = URL(string: destination),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    private static func renderCodeBlock(
        _ code: String,
        language: String?,
        traitCollection: UITraitCollection
    ) -> MarkdownCodeBlock {
        let bodyFont = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        let attributedCode = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular),
                .foregroundColor: UIColor.label
            ]
        )

        applySyntaxHighlighting(to: attributedCode, language: language)
        return MarkdownCodeBlock(language: language, code: code, attributedCode: attributedCode)
    }

    private static func normalizedCodeLanguage(_ language: String) -> String {
        switch language.lowercased() {
        case "js", "jsx", "javascript":
            return "javascript"
        case "ts", "tsx", "typescript":
            return "typescript"
        case "py", "python":
            return "python"
        case "sh", "bash", "zsh", "shell":
            return "shell"
        case "json", "swift":
            return language.lowercased()
        default:
            return language.lowercased()
        }
    }

    private static func applySyntaxHighlighting(to text: NSMutableAttributedString, language: String?) {
        guard text.length > 0 else { return }

        let fullRange = NSRange(location: 0, length: text.length)
        let source = text.string

        let commentPattern: String?
        let keywords: [String]

        switch language {
        case "swift":
            commentPattern = #"//.*$|/\*[\s\S]*?\*/"#
            keywords = [
                "actor", "as", "async", "await", "break", "case", "catch", "class", "continue",
                "default", "defer", "do", "else", "enum", "extension", "false", "for", "func",
                "guard", "if", "import", "in", "init", "let", "nil", "private", "protocol", "public",
                "return", "self", "some", "static", "struct", "switch", "throw", "throws", "true",
                "try", "var", "where", "while"
            ]
        case "python":
            commentPattern = #"#.*$"#
            keywords = [
                "and", "as", "async", "await", "break", "class", "continue", "def", "del", "elif",
                "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in",
                "is", "lambda", "None", "not", "or", "pass", "raise", "return", "True", "try", "while",
                "with", "yield"
            ]
        case "javascript", "typescript":
            commentPattern = #"//.*$|/\*[\s\S]*?\*/"#
            keywords = [
                "async", "await", "break", "case", "catch", "class", "const", "continue", "default",
                "delete", "do", "else", "export", "extends", "false", "finally", "for", "from", "function",
                "if", "import", "in", "instanceof", "let", "new", "null", "of", "return", "static",
                "super", "switch", "this", "throw", "true", "try", "typeof", "undefined", "var", "while"
            ]
        case "shell":
            commentPattern = #"#.*$"#
            keywords = ["case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "then", "while"]
        case "json":
            commentPattern = nil
            keywords = ["false", "null", "true"]
        default:
            commentPattern = #"//.*$|#.*$"#
            keywords = []
        }

        applyRegex(
            #"\b\d+(?:\.\d+)?\b"#,
            to: text,
            source: source,
            range: fullRange,
            color: .systemBlue
        )

        applyRegex(
            #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#,
            to: text,
            source: source,
            range: fullRange,
            color: .systemRed
        )

        if !keywords.isEmpty {
            let escaped = keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            applyRegex(
                "\\b(?:\(escaped))\\b",
                to: text,
                source: source,
                range: fullRange,
                color: .systemPurple
            )
        }

        if let commentPattern {
            applyRegex(
                commentPattern,
                options: [.anchorsMatchLines],
                to: text,
                source: source,
                range: fullRange,
                color: .secondaryLabel
            )
        }
    }

    private static func applyRegex(
        _ pattern: String,
        options: NSRegularExpression.Options = [],
        to text: NSMutableAttributedString,
        source: String,
        range: NSRange,
        color: UIColor
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        for match in expression.matches(in: source, range: range) {
            text.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private struct ListItem {
        let prefix: String
        let content: String
    }

    private static func parseListItem(_ line: String) -> ListItem? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return ListItem(prefix: "•\t", content: String(trimmed.dropFirst(marker.count)))
        }

        var digitEnd = trimmed.startIndex
        while digitEnd < trimmed.endIndex, trimmed[digitEnd].isNumber {
            digitEnd = trimmed.index(after: digitEnd)
        }
        guard digitEnd > trimmed.startIndex,
              digitEnd < trimmed.endIndex,
              trimmed[digitEnd] == "." else { return nil }

        let afterPeriod = trimmed.index(after: digitEnd)
        guard afterPeriod < trimmed.endIndex, trimmed[afterPeriod] == " " else { return nil }
        let number = trimmed[..<digitEnd]
        let contentStart = trimmed.index(after: afterPeriod)
        return ListItem(prefix: "\(number).\t", content: String(trimmed[contentStart...]))
    }

    private static func parseHeading(_ line: String) -> (level: Int, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var level = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index] == "#", level < 6 {
            level += 1
            index = trimmed.index(after: index)
        }
        guard level > 0,
              index < trimmed.endIndex,
              trimmed[index] == " " else { return nil }
        let content = String(trimmed[trimmed.index(after: index)...])
        return content.isEmpty ? nil : (level, content)
    }

    private static func parseBlockquote(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else { return nil }
        let content = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        return content.isEmpty ? nil : content
    }

    private static func appendHeading(
        _ heading: (level: Int, content: String),
        to output: NSMutableAttributedString,
        traitCollection: UITraitCollection
    ) {
        let textStyle: UIFont.TextStyle = switch heading.level {
        case 1: .title2
        case 2: .title3
        default: .headline
        }
        let base = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traitCollection)
        let font = UIFont.systemFont(ofSize: base.pointSize, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = heading.level <= 2 ? 8 : 5
        paragraph.paragraphSpacing = 4
        output.append(NSAttributedString(
            string: heading.content,
            attributes: [
                .font: font,
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraph
            ]
        ))
    }

    private static func appendBlockquote(
        _ quote: String,
        to output: NSMutableAttributedString,
        traitCollection: UITraitCollection
    ) {
        let bodyFont = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 12
        paragraph.headIndent = 12
        paragraph.paragraphSpacing = 3
        output.append(NSAttributedString(
            string: "▎ ",
            attributes: [
                .font: bodyFont,
                .foregroundColor: UIColor.tertiaryLabel,
                .paragraphStyle: paragraph
            ]
        ))
        appendInlineMarkdown(
            quote,
            to: output,
            traitCollection: traitCollection,
            paragraphStyle: paragraph
        )
    }

    private static func appendListItem(
        _ item: ListItem,
        to output: NSMutableAttributedString,
        traitCollection: UITraitCollection
    ) {
        let bodyFont = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        let paragraph = NSMutableParagraphStyle()
        let tabWidth = ("000. " as NSString).size(withAttributes: [.font: bodyFont]).width
        paragraph.firstLineHeadIndent = 0
        paragraph.headIndent = tabWidth
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: tabWidth)]

        append(
            item.prefix,
            style: [],
            to: output,
            traitCollection: traitCollection,
            paragraphStyle: paragraph
        )
        appendInlineMarkdown(
            item.content,
            to: output,
            traitCollection: traitCollection,
            paragraphStyle: paragraph
        )
    }
}
