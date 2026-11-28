//
//  LibraryCategoryBarHeaderView.swift
//  Aidoku
//
//  Created by Kodoku on 11/28/26.
//

import UIKit

/// Horizontal scrollable capsule pill bar replacing the Library category dropdown.
final class LibraryCategoryBarHeaderView: UICollectionReusableView {
    weak var delegate: LibraryCategorySelectionHeaderDelegate?

    private let outerStackView = UIStackView()
    private let scrollView = UIScrollView()
    private let pillStackView = UIStackView()
    private let quickJumpContainerView = UIView()
    private let quickJumpSeparatorView = UIView()
    private let quickJumpButton = UIButton(type: .system)

    private var snapshot: LibraryCategoryBarSnapshot?
    private var orderedPillButtons: [UIButton] = []
    private var selectedPillButton: UIButton?
    private var pendingScrollToSelected = false
    private var pendingScrollAnimated = false

    var currentSnapshot: LibraryCategoryBarSnapshot? { snapshot }
    var pillButtons: [UIButton] { orderedPillButtons }
    var isQuickJumpButtonHidden: Bool { quickJumpContainerView.isHidden }
    var quickJumpMenu: UIMenu? { quickJumpButton.menu }
    var currentScrollOffsetX: CGFloat { scrollView.contentOffset.x }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
        constrainViews()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleContentSizeCategoryDidChange),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with snapshot: LibraryCategoryBarSnapshot, animatedScroll: Bool = false) {
        guard snapshot != self.snapshot else { return }

        let hadPreviousSnapshot = self.snapshot != nil
        let selectionChanged = self.snapshot?.selectedIndexPath != snapshot.selectedIndexPath
        let shouldAnimateScroll = animatedScroll && hadPreviousSnapshot
        self.snapshot = snapshot

        quickJumpContainerView.isHidden = !snapshot.shouldShowQuickJumpButton
        pillStackView.directionalLayoutMargins.trailing = snapshot.shouldShowQuickJumpButton ? 8 : 16

        rebuildPills(from: snapshot)
        quickJumpButton.menu = makeQuickJumpMenu(from: snapshot)

        if selectionChanged {
            pendingScrollToSelected = true
            pendingScrollAnimated = shouldAnimateScroll
            if scrollView.bounds.width > 0 {
                layoutIfNeeded()
                scrollSelectedPillIntoView(animated: shouldAnimateScroll)
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if pendingScrollToSelected && scrollView.bounds.width > 0 {
            scrollView.layoutIfNeeded()
            scrollSelectedPillIntoView(animated: pendingScrollAnimated)
        }
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        guard let snapshot else { return }
        rebuildPills(from: snapshot)
    }
}

private extension LibraryCategoryBarHeaderView {
    func configureViews() {
        outerStackView.axis = .horizontal
        outerStackView.alignment = .fill
        outerStackView.spacing = 0
        addSubview(outerStackView)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.contentInsetAdjustmentBehavior = .never
        outerStackView.addArrangedSubview(scrollView)

        pillStackView.axis = .horizontal
        pillStackView.alignment = .center
        pillStackView.spacing = 8
        pillStackView.isLayoutMarginsRelativeArrangement = true
        pillStackView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        scrollView.addSubview(pillStackView)

        quickJumpSeparatorView.backgroundColor = .separator.withAlphaComponent(0.6)
        quickJumpContainerView.addSubview(quickJumpSeparatorView)

        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = .secondarySystemFill
        config.baseForegroundColor = .label
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        config.image = UIImage(systemName: "chevron.down", withConfiguration: symbolConfig)
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9)
        quickJumpButton.configuration = config
        quickJumpButton.showsMenuAsPrimaryAction = true
        quickJumpButton.accessibilityLabel = ForkL10n.string("LIBRARY_CATEGORIES_ALL_MENU")
        quickJumpButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        quickJumpButton.setContentHuggingPriority(.required, for: .horizontal)
        quickJumpContainerView.addSubview(quickJumpButton)

        quickJumpContainerView.setContentCompressionResistancePriority(.required, for: .horizontal)
        quickJumpContainerView.setContentHuggingPriority(.required, for: .horizontal)
        quickJumpContainerView.isHidden = true
        outerStackView.addArrangedSubview(quickJumpContainerView)
    }

    func constrainViews() {
        outerStackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        pillStackView.translatesAutoresizingMaskIntoConstraints = false
        quickJumpSeparatorView.translatesAutoresizingMaskIntoConstraints = false
        quickJumpButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            outerStackView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            outerStackView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            outerStackView.topAnchor.constraint(equalTo: topAnchor),
            outerStackView.bottomAnchor.constraint(equalTo: bottomAnchor),

            pillStackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            pillStackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            pillStackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            pillStackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            pillStackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),

            quickJumpSeparatorView.leadingAnchor.constraint(equalTo: quickJumpContainerView.leadingAnchor),
            quickJumpSeparatorView.centerYAnchor.constraint(equalTo: quickJumpContainerView.centerYAnchor),
            quickJumpSeparatorView.widthAnchor.constraint(equalToConstant: 1),
            quickJumpSeparatorView.heightAnchor.constraint(equalToConstant: 20),

            quickJumpButton.leadingAnchor.constraint(equalTo: quickJumpSeparatorView.trailingAnchor, constant: 8),
            quickJumpButton.trailingAnchor.constraint(equalTo: quickJumpContainerView.trailingAnchor, constant: -12),
            quickJumpButton.centerYAnchor.constraint(equalTo: quickJumpContainerView.centerYAnchor)
        ])
    }

    func rebuildPills(from snapshot: LibraryCategoryBarSnapshot) {
        for view in pillStackView.arrangedSubviews {
            pillStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        orderedPillButtons = []
        selectedPillButton = nil

        for (sectionIndex, section) in snapshot.sections.enumerated() {
            guard !section.items.isEmpty else { continue }
            if sectionIndex > 0 {
                pillStackView.addArrangedSubview(makeSectionDivider())
            }
            for item in section.items {
                let button = makePillButton(for: item)
                pillStackView.addArrangedSubview(button)
                orderedPillButtons.append(button)
                if item.isSelected {
                    selectedPillButton = button
                }
            }
        }
    }

    func makeSectionDivider() -> UIView {
        let divider = UIView()
        divider.backgroundColor = .separator.withAlphaComponent(0.6)
        divider.layer.cornerRadius = 0.5
        divider.isAccessibilityElement = false
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 18)
        ])
        return divider
    }

    func makePillButton(for item: LibraryCategoryBarItem) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        config.imagePadding = 5
        config.imagePlacement = .leading

        if let symbolName = leadingSymbolName(for: item) {
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            config.image = UIImage(systemName: symbolName, withConfiguration: symbolConfig)
        }

        if item.isSelected {
            config.baseBackgroundColor = tintColor
            config.baseForegroundColor = .white
        } else if item.kind == .filterGroup {
            config.baseBackgroundColor = tintColor.withAlphaComponent(0.12)
            config.baseForegroundColor = tintColor
            config.background.strokeColor = tintColor.withAlphaComponent(0.28)
            config.background.strokeWidth = 1
        } else {
            config.baseBackgroundColor = .secondarySystemFill
            config.baseForegroundColor = .label
        }

        var titleAttributes = AttributeContainer()
        titleAttributes.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 13, weight: item.isSelected ? .semibold : .medium),
            maximumPointSize: 17
        )
        config.attributedTitle = AttributedString(item.title, attributes: titleAttributes)

        let button = UIButton(
            configuration: config,
            primaryAction: UIAction { [weak self] _ in
                self?.handleSelection(indexPath: item.indexPath)
            }
        )
        button.isSelected = item.isSelected
        button.accessibilityLabel = item.title
        button.accessibilityTraits = item.isSelected ? [.button, .selected] : [.button]
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func leadingSymbolName(for item: LibraryCategoryBarItem) -> String? {
        if item.isLocked {
            return "lock.fill"
        }
        if item.kind == .filterGroup {
            return "line.3.horizontal.decrease"
        }
        return nil
    }

    func makeQuickJumpMenu(from snapshot: LibraryCategoryBarSnapshot) -> UIMenu {
        let menus = snapshot.sections.map { section in
            let actions = section.items.map { item in
                UIAction(
                    title: item.title,
                    image: leadingSymbolName(for: item).flatMap { UIImage(systemName: $0) },
                    state: item.isSelected ? .on : .off
                ) { [weak self] _ in
                    self?.handleSelection(indexPath: item.indexPath)
                }
            }
            return UIMenu(title: section.title ?? "", options: .displayInline, children: actions)
        }
        return UIMenu(children: menus)
    }

    func handleSelection(indexPath: IndexPath) {
        guard indexPath != snapshot?.selectedIndexPath else { return }
        delegate?.optionSelected(indexPath)
    }

    @objc func handleContentSizeCategoryDidChange() {
        guard let snapshot else { return }
        rebuildPills(from: snapshot)
        if scrollView.bounds.width > 0 {
            layoutIfNeeded()
            scrollSelectedPillIntoView(animated: false)
        }
    }

    func scrollSelectedPillIntoView(animated: Bool) {
        guard scrollView.bounds.width > 0 else { return }
        pendingScrollToSelected = false
        guard let selectedPillButton else { return }
        let pillFrame = scrollView.convert(selectedPillButton.bounds, from: selectedPillButton)
        let maxOffsetX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        let targetX = min(max(0, pillFrame.midX - scrollView.bounds.width / 2), maxOffsetX)
        scrollView.setContentOffset(CGPoint(x: targetX, y: 0), animated: animated)
    }
}
