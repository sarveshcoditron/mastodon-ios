//
//  NotificationTimelineViewModel.swift
//  Mastodon
//
//  Created by MainasuK on 2022-1-21.
//

import UIKit
import Combine
import CoreDataStack
import GameplayKit
import MastodonSDK
import MastodonCore
import MastodonLocalization

@MainActor
final class NotificationTimelineViewModel {
    
    var disposeBag = Set<AnyCancellable>()
    
    // input
    let context: AppContext
    let authenticationBox: MastodonAuthenticationBox
    let scope: Scope
    var notificationPolicy: Mastodon.Entity.NotificationPolicy?
    let dataController: FeedDataController
    @Published var isLoadingLatest = false
    @Published var lastAutomaticFetchTimestamp: Date?
    
    // output
    var diffableDataSource: UITableViewDiffableDataSource<NotificationSection, NotificationItem>?
    var didLoadLatest = PassthroughSubject<Void, Never>()

    // bottom loader
    private(set) lazy var loadOldestStateMachine: GKStateMachine = {
        // exclude timeline middle fetcher state
        let stateMachine = GKStateMachine(states: [
            LoadOldestState.Initial(viewModel: self),
            LoadOldestState.Loading(viewModel: self),
            LoadOldestState.Fail(viewModel: self),
            LoadOldestState.Idle(viewModel: self),
            LoadOldestState.NoMore(viewModel: self),
        ])
        stateMachine.enter(LoadOldestState.Initial.self)
        return stateMachine
    }()
    
    @MainActor
    init(
        context: AppContext,
        authenticationBox: MastodonAuthenticationBox,
        scope: Scope,
        notificationPolicy: Mastodon.Entity.NotificationPolicy? = nil
    ) {
        self.context = context
        self.authenticationBox = authenticationBox
        self.scope = scope
        self.dataController = FeedDataController(context: context, authenticationBox: authenticationBox)
        self.notificationPolicy = notificationPolicy

        switch scope {
        case .everything:
            self.dataController.records = (try? FileManager.default.cachedNotificationsAll(for: authenticationBox))?.map({ notification in
                MastodonFeed.fromNotification(notification, relationship: nil, kind: .notificationAll)
            }) ?? []
        case .mentions:
            self.dataController.records = (try? FileManager.default.cachedNotificationsMentions(for: authenticationBox))?.map({ notification in
                MastodonFeed.fromNotification(notification, relationship: nil, kind: .notificationMentions)
            }) ?? []
        case .fromAccount(_):
            self.dataController.records = []
        }

        self.dataController.$records
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: { feeds in
                let items: [Mastodon.Entity.Notification] = feeds.compactMap { feed -> Mastodon.Entity.Notification? in
                    guard let status = feed.notification else { return nil }
                    return status
                }
                switch self.scope {
                case .everything:
                    FileManager.default.cacheNotificationsAll(items: items, for: authenticationBox)
                case .mentions:
                    FileManager.default.cacheNotificationsMentions(items: items, for: authenticationBox)
                case .fromAccount(_):
                    //NOTE: we don't persist these
                    break
                }
            })
            .store(in: &disposeBag)

        NotificationCenter.default.addObserver(self, selector: #selector(Self.notificationFilteringChanged(_:)), name: .notificationFilteringChanged, object: nil)
    }

    //MARK: - Notifications

    @objc func notificationFilteringChanged(_ notification: Notification) {
        Task { [weak self] in
            guard let self else { return }

            let policy = try await APIService.shared.notificationPolicy(authenticationBox: self.authenticationBox)
            self.notificationPolicy = policy.value

            await self.loadLatest()
        }
    }
}

extension NotificationTimelineViewModel {
    enum Scope: Hashable {
        case everything
        case mentions
        case fromAccount(Mastodon.Entity.Account)

        var title: String {
            switch self {
            case .everything:
                return L10n.Scene.Notification.Title.everything
            case .mentions:
                return L10n.Scene.Notification.Title.mentions
            case .fromAccount(let account):
                return "Notifications from \(account.displayName)"
            }
        }
    }
}

extension NotificationTimelineViewModel {
    
    // load lastest
    func loadLatest() async {
        isLoadingLatest = true
        defer { isLoadingLatest = false }
        
        switch scope {
        case .everything:
            dataController.loadInitial(kind: .notificationAll)
        case .mentions:
            dataController.loadInitial(kind: .notificationMentions)
        case .fromAccount(let account):
            dataController.loadInitial(kind: .notificationAccount(account.id))
        }

        didLoadLatest.send()
    }
    
    // load timeline gap
    func loadMore(item: NotificationItem) async {
        switch scope {
        case .everything:
            dataController.loadNext(kind: .notificationAll)
        case .mentions:
            dataController.loadNext(kind: .notificationMentions)
        case .fromAccount(let account):
            dataController.loadNext(kind: .notificationAccount(account.id))
        }
    }
}
