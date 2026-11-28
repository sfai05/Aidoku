//
//  LibraryActiveFiltersHeaderView.swift
//  Aidoku
//
//  Created by Dokuha on 11/27/26.
//

import UIKit

/// Horizontal strip of removable active filter chips shown above the library collection.
final class LibraryActiveFiltersHeaderView: UICollectionReusableView {
    static let elementKind = "ForkLibraryActiveFiltersHeader"

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()

    private var currentChips: [LibraryActiveFilterChip] = []
    private var onRemoveFilter: ((LibraryFilter) -> Void)?
    private var onClearAll: (() -> Void)?

    var displayedChips: [LibraryActiveFilterChip] { currentChips }
    var arrangedChipViews: [UIView] { stackView.arrangedSubviews }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
        constrainViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        chips: [LibraryActiveFilterChip],
        onRemoveFilter: @escaping (LibraryFilter) -> Void,
        onClearAll: @escaping () -> Void
    ) {
        self.onRemoveFilter = onRemoveFilter
        self.onClearAll = onClearAll

        guard chips != currentChips else { return }
        currentChips = chips
        rebuildChips()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        guard !currentChips.isEmpty else { return }
        rebuildChips()
    }
}

private extension LibraryActiveFiltersHeaderView {
    func configureViews() {
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        addSubview(scrollView)

        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 8
        stackView.isLayoutMarginsRelativeArrangement = true
        stackView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        scrollView.addSubview(stackView)
    }

    func constrainViews() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stackView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
    }

    func rebuildChips() {
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for chip in currentChips {
            stackView.addArrangedSubview(makeChipButton(for: chip))
        }

        if currentChips.count >= 2 {
            stackView.addArrangedSubview(makeClearAllButton())
        }
    }

    func makeChipButton(for chip: LibraryActiveFilterChip) -> UIButton {
        let accent: UIColor = chip.isExcluded ? .systemRed : tintColor
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = accent.withAlphaComponent(0.14)
        config.baseForegroundColor = accent
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
        config.imagePadding = 5
        config.imagePlacement = .trailing

        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        config.image = UIImage(systemName: "xmark", withConfiguration: symbolConfig)

        var titleAttributes = AttributeContainer()
        titleAttributes.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(ofSize: 12, weight: .semibold),
            maximumPointSize: 16
        )
        config.attributedTitle = AttributedString(chip.title, attributes: titleAttributes)

        let button = UIButton(
            configuration: config,
            primaryAction: UIAction { [weak self] _ in
                self?.onRemoveFilter?(chip.filter)
            }
        )
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.accessibilityLabel = ForkL10n.format("LIBRARY_REMOVE_FILTER_CHIP_A11Y_FORMAT", chip.title)
        return button
    }

    func makeClearAllButton() -> UIButton {
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 6, bottom: 5, trailing: 6)
        config.baseForegroundColor = .secondaryLabel

        var titleAttributes = AttributeContainer()
        titleAttributes.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(ofSize: 12, weight: .medium),
            maximumPointSize: 16
        )
        config.attributedTitle = AttributedString(NSLocalizedString("CLEAR_FILTERS"), attributes: titleAttributes)

        let button = UIButton(
            configuration: config,
            primaryAction: UIAction { [weak self] _ in
                self?.onClearAll?()
            }
        )
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
}
