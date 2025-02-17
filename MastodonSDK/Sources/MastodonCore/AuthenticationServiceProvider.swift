// Copyright © 2023 Mastodon gGmbH. All rights reserved.

import Foundation
import Combine
import CoreDataStack
import MastodonSDK
import KeychainAccess
import MastodonCommon
import os.log

@MainActor
public class AuthenticationServiceProvider: ObservableObject {
    private let logger = Logger(subsystem: "AuthenticationServiceProvider", category: "Authentication")

    public static let shared = AuthenticationServiceProvider()
    private static let keychain = Keychain(service: "org.joinmastodon.app.authentications", accessGroup: AppName.groupID)
    private let userDefaults: UserDefaults = .shared

    var disposeBag = Set<AnyCancellable>()
    
    public let currentActiveUser = CurrentValueSubject<MastodonAuthenticationBox?, Never>(nil)
    @Published public var mastodonAuthenticationBoxes: [MastodonAuthenticationBox] = []
    public let updateActiveUserAccountPublisher = PassthroughSubject<Void, Never>()
    
    private init() {
        prepareForUse()
        
        $mastodonAuthenticationBoxes
            .throttle(for: 3, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] boxes in
                guard let nowActive = boxes.first else { return }
                Task { [weak self] in
                    try await self?.fetchFollowedBlockedUserIds(nowActive)
                }
            }
            .store(in: &disposeBag)

        // TODO: verify credentials for active authentication
        
        Task {
            if authenticationMigrationRequired {
                migrateLegacyAuthentications(
                    in: PersistenceManager.shared.mainActorManagedObjectContext
                )
            }
        }
    }
    
    private func authenticationBoxes(_ authentications: [MastodonAuthentication]) -> [MastodonAuthenticationBox] {
        return authentications
            .sorted(by: { $0.activedAt > $1.activedAt })
            .compactMap { authentication -> MastodonAuthenticationBox? in
                return MastodonAuthenticationBox(authentication: authentication)
            }
    }
    
    private var authentications: [MastodonAuthentication] = [] {
        didSet {
            let boxes = authenticationBoxes(authentications)
            let nowActive = boxes.first
            if nowActive?.authentication != self.currentActiveUser.value?.authentication {
                self.currentActiveUser.send(nowActive)
            }
            mastodonAuthenticationBoxes = boxes
            persist(authentications)
        }
    }

    @MainActor
    @discardableResult
    func updating(instanceV1 instance: Mastodon.Entity.Instance, for domain: String) -> Self {
        authentications = authentications.map { authentication in
            guard authentication.domain == domain else { return authentication }
            return authentication.updating(instanceV1: instance)
        }
        return self
    }
    
    @MainActor
    @discardableResult
    func updating(instanceV2 instance: Mastodon.Entity.V2.Instance, for domain: String) -> Self {
        authentications = authentications.map { authentication in
            guard authentication.domain == domain else { return authentication }
            return authentication.updating(instanceV2: instance)
        }
        return self
    }
    
    @MainActor
    @discardableResult
    func updating(translationLanguages: TranslationLanguages, for domain: String) -> Self {
        authentications = authentications.map { authentication in
            guard authentication.domain == domain else { return authentication }
            return authentication.updating(translationLanguages: translationLanguages)
        }
        return self
    }
    
    @MainActor
    func delete(authentication: MastodonAuthentication) throws {
        try Self.keychain.remove(authentication.persistenceIdentifier)
        authentications.removeAll(where: { $0 == authentication })
    }
    
    public func activateExistingUser(_ userID: String, inDomain domain: String) -> Bool {
        var found = false
        authentications = authentications.map { authentication in
            guard authentication.domain == domain, authentication.userID == userID else {
                return authentication
            }
            found = true
            return authentication.updating(activatedAt: Date())
        }
        return found
    }
    
    public func activateExistingUserToken(_ accessToken: String) -> MastodonAuthenticationBox? {
        guard let match = mastodonAuthenticationBoxes.first(where: { $0.authentication.userAccessToken == accessToken }) else { return nil }
        guard activateExistingUser(match.userID, inDomain: match.domain) else { return nil }
        return match
    }
    
    public func activateAuthentication(_ authenticationBox: MastodonAuthenticationBox) {
        if activateExistingUser(authenticationBox.userID, inDomain: authenticationBox.domain) {
            return
        } else {
            authentications.insert(authenticationBox.authentication, at: 0)
            _ = activateExistingUser(authenticationBox.userID, inDomain: authenticationBox.domain)
        }
        
    }
}

// MARK: - Public
public extension AuthenticationServiceProvider {
    func getAuthentication(matching userAccessToken: String) -> MastodonAuthentication? {
        authentications.first(where: { $0.userAccessToken == userAccessToken })
    }

    
    
    func fetchFollowingAndBlockedAsync() {
        /// We're dispatching this as a separate async call to not block the caller
        /// Also we'll only be updating the current active user as the state will be refreshed upon user-change anyways
        Task {
            if let authBox = currentActiveUser.value {
                do { try await fetchFollowedBlockedUserIds(authBox) }
                catch {}
            }
        }
    }
    
    func signOutMastodonUser(authentication: MastodonAuthentication) async throws {
        try AuthenticationServiceProvider.shared.delete(authentication: authentication)
        _ = try await APIService.shared.cancelSubscription(domain: authentication.domain, authorization: authentication.authorization)
    }
    
    @MainActor
    private func prepareForUse() {
        if authentications.isEmpty {
            restoreFromKeychain()
        }
        mastodonAuthenticationBoxes = authenticationBoxes(authentications)
        currentActiveUser.send(mastodonAuthenticationBoxes.first)
    }

    @MainActor
    private func restoreFromKeychain() {
        var keychainAuthentications: [MastodonAuthentication] = Self.keychain.allKeys().compactMap {
            guard
                let encoded = Self.keychain[$0],
                let data = Data(base64Encoded: encoded)
            else { return nil }
            return try? JSONDecoder().decode(MastodonAuthentication.self, from: data)
        }
        .sorted(by: { $0.activedAt > $1.activedAt })
        let cachedAccounts = keychainAuthentications.compactMap {
            $0.cachedAccount()
        }
        if cachedAccounts.count == 0 {
            // Assume this is a fresh install.
            // Clear the keychain of any accounts remaining from previous installs.
            for authentication in keychainAuthentications {
                try? delete(authentication: authentication)
            }
            keychainAuthentications = []
        }
        self.authentications = keychainAuthentications
    }
    
    func updateAccountCreatedAt(_ newCreatedAt: Date, forAuthentication outdated: MastodonAuthentication) {
        authentications = authentications.map { authentication in
            guard authentication == outdated else {
                return authentication
            }
            return outdated.updating(accountCreatedAt: newCreatedAt)
        }
    }

    func migrateLegacyAuthentications(in context: NSManagedObjectContext) {
        do {
            let legacyAuthentications = try context.fetch(MastodonAuthenticationLegacy.sortedFetchRequest)
            let migratedAuthentications = legacyAuthentications.compactMap { auth -> MastodonAuthentication? in
                return MastodonAuthentication(
                    identifier: auth.identifier,
                    domain: auth.domain,
                    username: auth.username,
                    appAccessToken: auth.appAccessToken,
                    userAccessToken: auth.userAccessToken,
                    clientID: auth.clientID,
                    clientSecret: auth.clientSecret,
                    createdAt: auth.createdAt,
                    updatedAt: auth.updatedAt,
                    activedAt: auth.activedAt,
                    userID: auth.userID,
                    instanceConfiguration: nil,
                    accountCreatedAt: auth.createdAt
                )
            }

            if migratedAuthentications.count != legacyAuthentications.count {
                logger.log(level: .default, "Not all account authentications could be migrated.")
            } else {
                logger.log(level: .default, "All account authentications were successful.")
            }

            DispatchQueue.main.async {
                self.authentications = migratedAuthentications
                self.userDefaults.didMigrateAuthentications = true
            }
        } catch {
            userDefaults.didMigrateAuthentications = false
            logger.log(level: .error, "Could not migrate legacy authentications")
        }
    }

    var authenticationMigrationRequired: Bool {
        userDefaults.didMigrateAuthentications == false
    }

    func fetchAccounts() async {
        // FIXME: This is a dirty hack to make the performance-stuff work.
        // Problem is, that we don't persist the user on disk anymore. So we have to fetch
        // it when we need it to display on the home timeline.
        // We need this (also) for the Account-list, but it might be the wrong place. App Startup might be more appropriate
        for authentication in authentications {
            guard let account = try? await APIService.shared.accountInfo(MastodonAuthenticationBox(authentication: authentication)) else { continue }
        }

        NotificationCenter.default.post(name: .userFetched, object: nil)
    }
}

// MARK: - Private
private typealias IterativeResponse = (ids: [String], maxID: String?)
private extension AuthenticationServiceProvider {
    func persist(_ authentications: [MastodonAuthentication]) {
        DispatchQueue.main.async {
            for authentication in authentications {
                Self.keychain[authentication.persistenceIdentifier] = try? JSONEncoder().encode(authentication).base64EncodedString()
            }
        }
    }
    
    func fetchFollowedBlockedUserIds(
        _ authBox: MastodonAuthenticationBox,
        _ previousFollowingIDs: [String]? = nil,
        _ maxID: String? = nil
    ) async throws {
        let apiService = APIService.shared
        
        let followingResponse = try await fetchFollowing(maxID, apiService, authBox)
        let followingIds = (previousFollowingIDs ?? []) + followingResponse.ids
        
        if let nextMaxID = followingResponse.maxID {
            return try await fetchFollowedBlockedUserIds(authBox, followingIds, nextMaxID)
        }
        
        let blockedIds = try await apiService.getBlocked(
            authenticationBox: authBox
        ).value.map { $0.id }
        
        let followRequestIds = try await apiService.pendingFollowRequest(userID: authBox.userID,
                                                                         authenticationBox: authBox)
            .value.map { $0.id }
        
        authBox.inMemoryCache.followRequestedUserIDs = followRequestIds
        authBox.inMemoryCache.followingUserIds = followingIds
        authBox.inMemoryCache.blockedUserIds = blockedIds
    }
    
    private func fetchFollowing(
        _ maxID: String?,
        _ apiService: APIService,
        _ mastodonAuthenticationBox: MastodonAuthenticationBox
    ) async throws -> IterativeResponse {
        let response = try await apiService.following(
            userID: mastodonAuthenticationBox.userID,
            maxID: maxID,
            authenticationBox: mastodonAuthenticationBox
        )
        
        let ids: [String] = response.value.map { $0.id }
        let maxID: String? = response.link?.maxID
        
        return (ids, maxID)
    }
}
