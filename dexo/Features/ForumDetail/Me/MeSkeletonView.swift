import UIKit

/// Skeleton placeholder shown while the Me profile is loading.
/// Mimics the layout of ProfileHeaderView + 2 table rows.
final class MeSkeletonView: UIView {
    private var shimmers: [ShimmerView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func makeShimmer(height: CGFloat, width: CGFloat? = nil, radius: CGFloat = 4) -> ShimmerView {
        let v = ShimmerView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.layer.cornerRadius = radius
        v.clipsToBounds = true
        var constraints = [v.heightAnchor.constraint(equalToConstant: height)]
        if let width { constraints.append(v.widthAnchor.constraint(equalToConstant: width)) }
        NSLayoutConstraint.activate(constraints)
        shimmers.append(v)
        return v
    }

    private func setup() {
        // --- Header area ---
        let avatar = makeShimmer(height: 68, width: 68, radius: 34)
        let nameLine = makeShimmer(height: 16)
        let usernameLine = makeShimmer(height: 12)

        let nameStack = UIStackView(arrangedSubviews: [nameLine, usernameLine])
        nameStack.axis = .vertical
        nameStack.spacing = 6

        let avatarRow = UIStackView(arrangedSubviews: [avatar, nameStack])
        avatarRow.axis = .horizontal
        avatarRow.alignment = .center
        avatarRow.spacing = 12

        // Stats row: 4 blocks
        let statsRow = UIStackView()
        statsRow.axis = .horizontal
        statsRow.distribution = .fillEqually
        statsRow.spacing = 8
        for _ in 0..<4 {
            let block = UIStackView(arrangedSubviews: [
                makeShimmer(height: 20, width: 32),
                makeShimmer(height: 10, width: 40),
            ])
            block.axis = .vertical
            block.alignment = .center
            block.spacing = 4
            statsRow.addArrangedSubview(block)
        }

        let headerStack = UIStackView(arrangedSubviews: [avatarRow, statsRow])
        headerStack.axis = .vertical
        headerStack.spacing = 20
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(headerStack)

        // --- Table row placeholders ---
        let rowsStack = UIStackView()
        rowsStack.axis = .vertical
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        for i in 0..<2 {
            let icon = makeShimmer(height: 16, width: 16, radius: 4)
            let label = makeShimmer(height: 14)
            let row = UIStackView(arrangedSubviews: [icon, label])
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 12

            let rowContainer = UIView()
            rowContainer.translatesAutoresizingMaskIntoConstraints = false
            row.translatesAutoresizingMaskIntoConstraints = false
            rowContainer.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: rowContainer.leadingAnchor, constant: 20),
                row.trailingAnchor.constraint(equalTo: rowContainer.trailingAnchor, constant: -20),
                row.topAnchor.constraint(equalTo: rowContainer.topAnchor, constant: 14),
                row.bottomAnchor.constraint(equalTo: rowContainer.bottomAnchor, constant: -14),
            ])

            if i < 1 {
                let sep = UIView()
                sep.backgroundColor = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                rowContainer.addSubview(sep)
                NSLayoutConstraint.activate([
                    sep.leadingAnchor.constraint(equalTo: rowContainer.leadingAnchor, constant: 52),
                    sep.trailingAnchor.constraint(equalTo: rowContainer.trailingAnchor),
                    sep.bottomAnchor.constraint(equalTo: rowContainer.bottomAnchor),
                    sep.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
                ])
            }

            rowsStack.addArrangedSubview(rowContainer)
        }

        let rowsCard = UIView()
        rowsCard.backgroundColor = ThemeManager.shared.cardBackgroundColor
        rowsCard.layer.cornerRadius = 10
        rowsCard.clipsToBounds = true
        rowsCard.translatesAutoresizingMaskIntoConstraints = false
        rowsCard.addSubview(rowsStack)

        addSubview(rowsCard)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            headerStack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 32),
            headerStack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -32),

            rowsCard.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 28),
            rowsCard.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 20),
            rowsCard.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -20),

            rowsStack.topAnchor.constraint(equalTo: rowsCard.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: rowsCard.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: rowsCard.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: rowsCard.bottomAnchor),
        ])
    }
}
