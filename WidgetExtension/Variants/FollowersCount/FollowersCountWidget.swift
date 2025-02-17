// Copyright © 2023 Mastodon gGmbH. All rights reserved.

import WidgetKit
import SwiftUI
import Intents
import MastodonSDK
import MastodonCore
import MastodonLocalization

struct FollowersCountWidgetProvider: IntentTimelineProvider {
    private let followersHistory = FollowersCountHistory.shared
    
    func placeholder(in context: Context) -> FollowersCountEntry {
        .placeholder
    }

    func getSnapshot(for configuration: FollowersCountIntent, in context: Context, completion: @escaping (FollowersCountEntry) -> ()) {
        loadCurrentEntry(for: configuration, in: context, completion: completion)
    }

    func getTimeline(for configuration: FollowersCountIntent, in context: Context, completion: @escaping (Timeline<FollowersCountEntry>) -> ()) {
        loadCurrentEntry(for: configuration, in: context) { entry in
            completion(Timeline(entries: [entry], policy: .after(.now)))
        }
    }
}

struct FollowersCountEntry: TimelineEntry {
    let date: Date
    let account: FollowersEntryAccountable?
    let configuration: FollowersCountIntent
    
    static var placeholder: Self {
        FollowersCountEntry(
            date: .now,
            account: FollowersEntryAccount(
                followersCount: 99_900,
                displayNameWithFallback: "Mastodon",
                acct: "mastodon",
                avatarImage: UIImage(named: "missingAvatar")!,
                domain: "mastodon"
            ),
            configuration: FollowersCountIntent()
        )
    }
    
    static var unconfigured: Self {
        FollowersCountEntry(
            date: .now,
            account: nil,
            configuration: FollowersCountIntent()
        )
    }
}

struct FollowersCountWidget: Widget {
    private var availableFamilies: [WidgetFamily] {
        return [.systemSmall, .accessoryRectangular, .accessoryCircular]
    }

    var body: some WidgetConfiguration {
        IntentConfiguration(kind: "Followers", intent: FollowersCountIntent.self, provider: FollowersCountWidgetProvider()) { entry in
            FollowersCountWidgetView(entry: entry)
        }
        .configurationDisplayName(L10n.Widget.FollowersCount.configurationDisplayName)
        .description(L10n.Widget.FollowersCount.configurationDescription)
        .supportedFamilies(availableFamilies)
        .contentMarginsDisabled() // Disable excessive margins (only effective for iOS >= 17.0
    }
}

private extension FollowersCountWidgetProvider {
    func loadCurrentEntry(for configuration: FollowersCountIntent, in context: Context, completion: @escaping (FollowersCountEntry) -> Void) {
        Task { @MainActor in

            guard
                let authBox = AuthenticationServiceProvider.shared.currentActiveUser.value
            else {
                guard !context.isPreview else {
                    return completion(.placeholder)
                }
                return completion(.unconfigured)
            }
            
            guard
                let desiredAccount = configuration.account ?? authBox.cachedAccount?.acctWithDomain
            else {
                return completion(.unconfigured)
            }
            
            guard
                let resultingAccount = try? await APIService.shared
                    .search(query: .init(q: desiredAccount, type: .accounts), authenticationBox: authBox)
                    .value
                    .accounts
                    .first(where: { $0.acctWithDomainIfMissing(authBox.domain) == desiredAccount })
            else {
                return completion(.unconfigured)
            }
            
            let imageData = try? await URLSession.shared.data(from: resultingAccount.avatarImageURLWithFallback(domain: authBox.domain)).0
            let avatarImage: UIImage
            if let imageData {
                avatarImage = UIImage(data: imageData) ?? UIImage(named: "missingAvatar")!
            } else {
                avatarImage = UIImage(named: "missingAvatar")!
            }
            let entry = FollowersCountEntry(
                date: Date(),
                account: FollowersEntryAccount.from(
                    mastodonAccount: resultingAccount,
                    domain: authBox.domain,
                    avatarImage: avatarImage
                ),
                configuration: configuration
            )
            
            followersHistory.updateFollowersTodayCount(
                account: entry.account!,
                count: resultingAccount.followersCount
            )
            
            completion(entry)
        }
    }
}

protocol FollowersEntryAccountable {
    var followersCount: Int { get }
    var displayNameWithFallback: String { get }
    var acct: String { get }
    var avatarImage: UIImage { get }
    var domain: String { get }
}

struct FollowersEntryAccount: FollowersEntryAccountable {
    let followersCount: Int
    let displayNameWithFallback: String
    let acct: String
    let avatarImage: UIImage
    let domain: String
    
    static func from(mastodonAccount: Mastodon.Entity.Account, domain: String, avatarImage: UIImage) -> Self {
        FollowersEntryAccount(
            followersCount: mastodonAccount.followersCount,
            displayNameWithFallback: mastodonAccount.displayNameWithFallback,
            acct: mastodonAccount.acct,
            avatarImage: avatarImage,
            domain: domain
        )
    }
}
