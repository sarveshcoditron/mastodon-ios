//
//  StatusView+Configuration.swift
//  Mastodon
//
//  Created by MainasuK on 2022-1-12.
//

import UIKit
import Combine
import CoreDataStack
import MastodonSDK
import MastodonCore
import MastodonLocalization
import MastodonMeta
import Meta
import NaturalLanguage

extension StatusView {
    
    static let statusFilterWorkingQueue = DispatchQueue(label: "StatusFilterWorkingQueue")
    
    public func configure(feed: MastodonFeed) {
        switch feed.kind {
        case .home:
            guard let status = feed.status else {
                assertionFailure()
                return
            }
            configure(status: status)
        case .notificationAll:
            assertionFailure("TODO")
        case .notificationMentions:
            assertionFailure("TODO")
        case .none:
            break
        }
        
    }
}

extension StatusView {

    public func configure(status: MastodonStatus, statusEdit: Mastodon.Entity.StatusEdit) {
        configureHeader(status: status)
        let author = (status.reblog ?? status).entity.account
        configureAuthor(author: author)
        configureTimestamp(timestamp: (status.reblog ?? status).entity.createdAt)
        configureApplicationName(status.entity.application?.name)
        configureMedia(status: status)
        configurePollHistory(statusEdit: statusEdit)
        configureCard(status: status)
        configureToolbar(status: status)
        configureFilter(status: status)
        configureContent(statusEdit: statusEdit, status: status)
        configureMedia(status: statusEdit)
        actionToolbarAdaptiveMarginContainerView.isHidden = true
        authorView.menuButton.isHidden = true
        headerAdaptiveMarginContainerView.isHidden = true
        viewModel.isSensitiveToggled = true
        viewModel.isContentReveal = true
    }

    public func configure(status: MastodonStatus) {
        configureHeader(status: status)
        let author = (status.reblog ?? status).entity.account
        configureAuthor(author: author)
        let timestamp = (status.reblog ?? status).entity.createdAt
        configureTimestamp(timestamp: timestamp)
        configureApplicationName(status.entity.application?.name)
        configureContent(status: status)
        configureMedia(status: status)
        configurePoll(status: status)
        configureCard(status: status)
        configureToolbar(status: status)
        configureFilter(status: status)
        viewModel.originalStatus = status

        viewModel.$translation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] translation in
                self?.configureTranslated(status: status)
            }
            .store(in: &disposeBag)
    }
}

extension StatusView {
    private func configureHeader(status: MastodonStatus) {
        if status.entity.reblogged == true, 
            let authenticationBox = viewModel.authenticationBox,
           let account = authenticationBox.cachedAccount {

            let name = account.displayNameWithFallback
            let emojis = account.emojis

            viewModel.header = {
                let text = L10n.Common.Controls.Status.userReblogged(name)
                let content = MastodonContent(content: text, emojis: emojis.asDictionary)
                do {
                    let metaContent = try MastodonMetaContent.convert(document: content)
                    return .repost(info: .init(header: metaContent))
                } catch {
                    let metaContent = PlaintextMetaContent(string: name)
                    return .repost(info: .init(header: metaContent))
                }
            }()
        } else if status.reblog != nil {
            let name = status.entity.account.displayNameWithFallback
            let emojis = status.entity.account.emojis

            viewModel.header = {
                let text = L10n.Common.Controls.Status.userReblogged(name)
                let content = MastodonContent(content: text, emojis: emojis.asDictionary)
                do {
                    let metaContent = try MastodonMetaContent.convert(document: content)
                    return .repost(info: .init(header: metaContent))
                } catch {
                    let metaContent = PlaintextMetaContent(string: name)
                    return .repost(info: .init(header: metaContent))
                }
            }()

        } else if let _ = status.entity.inReplyToID,
                  let inReplyToAccountID = status.entity.inReplyToAccountID
        {
            func createHeader(
                name: String?,
                emojis: MastodonContent.Emojis?
            ) -> ViewModel.Header {
                let fallbackMetaContent = PlaintextMetaContent(string: L10n.Common.Controls.Status.userRepliedTo("-"))
                let fallbackReplyHeader = ViewModel.Header.reply(info: .init(header: fallbackMetaContent))
                guard let name = name,
                      let emojis = emojis
                else {
                    return fallbackReplyHeader
                }
                
                let content = MastodonContent(content: L10n.Common.Controls.Status.userRepliedTo(name), emojis: emojis)
                guard let metaContent = try? MastodonMetaContent.convert(document: content) else {
                    return fallbackReplyHeader
                }
                let header = ViewModel.Header.reply(info: .init(header: metaContent))
                return header
            }

            if let inReplyToID = status.entity.inReplyToID {
                // A. replyTo status exist
                
                /// we need to initially set an empty header, otherwise the layout gets messed up
                viewModel.header = createHeader(name: "", emojis: [:])
                /// finally we can load the status information and display the correct header
                if let authenticationBox = viewModel.authenticationBox {
                    Mastodon.API.Statuses.status(
                        session: .shared,
                        domain: authenticationBox.domain,
                        statusID: inReplyToID,
                        authorization: authenticationBox.userAuthorization
                    )
                    .receive(on: DispatchQueue.main)
                    .sink(receiveCompletion: { completion in
                        // no-op
                    }, receiveValue: { [weak self] response in
                        guard let self else { return }
                        let replyTo = response.value
                        let header = createHeader(name: replyTo.account.displayNameWithFallback, emojis: replyTo.account.emojis.asDictionary)
                        self.viewModel.header = header
                    })
                    .store(in: &disposeBag)
                }
            } else {
                // B. replyTo status not exist
                    let header = createHeader(name: nil, emojis: nil)
                    viewModel.header = header
                    
                    if let authenticationBox = viewModel.authenticationBox {
                        Just(inReplyToAccountID)
                            .asyncMap { userID in
                                return try await Mastodon.API.Account.accountInfo(
                                    session: .shared,
                                    domain: authenticationBox.domain,
                                    userID: userID,
                                    authorization: authenticationBox.userAuthorization
                                ).singleOutput()
                            }
                            .receive(on: DispatchQueue.main)
                            .sink { completion in
                                // do nothing
                            } receiveValue: { [weak self] response in
                                guard let self = self else { return }
                                let user = response.value
                                let header = createHeader(name: user.displayNameWithFallback, emojis: user.emojiMeta)
                                self.viewModel.header = header
                            }
                            .store(in: &disposeBag)
                    }   // end if let
            }   // end else B.
            
        } else {
            viewModel.header = .none
        }
    }
    
    public func configureAuthor(author: Mastodon.Entity.Account) {
        Task { @MainActor in
            
            // author avatar
            viewModel.authorAvatarImageURL = author.avatarImageURL()
            let emojis = author.emojis.asDictionary

            // author name
            viewModel.authorName = {
                do {
                    let content = MastodonContent(content: author.displayNameWithFallback, emojis: emojis)
                    let metaContent = try MastodonMetaContent.convert(document: content)
                    return metaContent
                } catch {
                    assertionFailure(error.localizedDescription)
                    return PlaintextMetaContent(string: author.displayNameWithFallback)
                }
            }()
            
            viewModel.authorId = author.id
            
            // author username
            viewModel.authorUsername = author.acct
            
            // locked
            viewModel.locked = author.locked
                        
            // isMyself
            viewModel.isMyself = {
                guard let authenticationBox = viewModel.authenticationBox else { return false }
                return authenticationBox.domain == author.domain && authenticationBox.userID == author.id
            }()
            
            // isMuting, isBlocking, Following
            guard viewModel.authenticationBox != nil else { return }
            guard !viewModel.isMyself else {
                viewModel.isMuting = false
                viewModel.isBlocking = false
                viewModel.isFollowed = false
                return
            }
        }
    }
    
    private func configureTimestamp(timestamp: Date) {
        // timestamp
        viewModel.timestampFormatter = { (date: Date, isEdited: Bool) in
            if isEdited {
                return L10n.Common.Controls.Status.editedAtTimestampPrefix(date.localizedAbbreviatedSlowedTimeAgoSinceNow)
            } else {
                return date.localizedAbbreviatedSlowedTimeAgoSinceNow
            }
        }
        viewModel.timestamp = timestamp
    }

    private func configureApplicationName(_ applicationName: String?) {
        viewModel.applicationName = applicationName
    }
    
    public func revertTranslation() {
        guard let originalStatus = viewModel.originalStatus else { return }
        
        viewModel.translation = nil
        configure(status: originalStatus)
    }
    
    func configureTranslated(status: MastodonStatus) {
        guard let translation = viewModel.translation,
              let translatedContent = translation.content else {
            viewModel.isCurrentlyTranslating = false
            return
        }

        // content
        do {
            let content = MastodonContent(content: translatedContent, emojis: status.entity.emojis.asDictionary)
            let metaContent = try MastodonMetaContent.convert(document: content)
            viewModel.content = metaContent
            viewModel.isCurrentlyTranslating = false
        } catch {
            assertionFailure(error.localizedDescription)
            viewModel.content = PlaintextMetaContent(string: "")
        }
    }

    private func configureContent(statusEdit: Mastodon.Entity.StatusEdit, status: MastodonStatus) {
        statusEdit.spoilerText.map {
            viewModel.spoilerContent = PlaintextMetaContent(string: $0)
        }
        
        // language
        viewModel.language = (status.reblog ?? status).entity.language
        // content
        do {
            let content = MastodonContent(content: statusEdit.content, emojis: statusEdit.emojis.asDictionary)
            let metaContent = try MastodonMetaContent.convert(document: content)
            viewModel.content = metaContent
            viewModel.isCurrentlyTranslating = false
        } catch {
            assertionFailure(error.localizedDescription)
            viewModel.content = PlaintextMetaContent(string: "")
        }
    }

    private func configureContent(status: MastodonStatus) {
        guard viewModel.translation == nil else {
            return configureTranslated(status: status)
        }
        
        let status = status.reblog ?? status
        
        // spoilerText
        if let spoilerText = status.entity.spoilerText, !spoilerText.isEmpty {
            do {
                let content = MastodonContent(content: spoilerText, emojis: status.entity.emojis.asDictionary)
                let metaContent = try MastodonMetaContent.convert(document: content)
                viewModel.spoilerContent = metaContent
            } catch {
                assertionFailure(error.localizedDescription)
                viewModel.spoilerContent = PlaintextMetaContent(string: "")
            }
        } else {
            viewModel.spoilerContent = nil
        }
        // language
        viewModel.language = (status.reblog ?? status).entity.language
        // content
        do {
            let content = MastodonContent(content: status.entity.content ?? "", emojis: status.entity.emojis.asDictionary)
            let metaContent = try MastodonMetaContent.convert(document: content)
            viewModel.content = metaContent
            viewModel.isCurrentlyTranslating = false
        } catch {
            assertionFailure(error.localizedDescription)
            viewModel.content = PlaintextMetaContent(string: "")
        }
        // visibility
        viewModel.visibility = status.entity.mastodonVisibility

        // sensitive
        viewModel.isContentSensitive = status.entity.sensitive == true
        viewModel.isSensitiveToggled = status.isSensitiveToggled

    }
    
    private func configureMedia(status: MastodonStatus) {
        let status = status.reblog ?? status
        
        viewModel.isMediaSensitive = status.entity.sensitive == true
        
        let configurations = MediaView.configuration(status: status)
        viewModel.mediaViewConfigurations = configurations
    }
    
    private func configureMedia(status: Mastodon.Entity.StatusEdit) {
        viewModel.isMediaSensitive = status.sensitive
        
        let configurations = MediaView.configuration(status: status)
        viewModel.mediaViewConfigurations = configurations
    }
    
    private func configurePollHistory(statusEdit: Mastodon.Entity.StatusEdit) {
        guard let poll = statusEdit.poll else { return }

        let pollItems = poll.options.map { PollItem.history(option: $0) }
        self.viewModel.pollItems = pollItems
        pollStatusStackView.isHidden = true

        var _snapshot = NSDiffableDataSourceSnapshot<PollSection, PollItem>()
        _snapshot.appendSections([.main])
        _snapshot.appendItems(pollItems, toSection: .main)
        pollTableViewDiffableDataSource?.applySnapshotUsingReloadData(_snapshot)
    }

    private func configurePoll(status: MastodonStatus) {
        let status = status.reblog ?? status
        
        guard let poll = status.poll else {
            return
        }

        let options = poll.options
        let items: [PollItem] = options.map { .option(record: $0) }
        self.viewModel.pollItems = items

        let hasSelectedOption = options.contains(where: { $0.isSelected == true })
        viewModel.isVoteButtonEnabled = hasSelectedOption

        Publishers.CombineLatest(
            poll.$voted,
            poll.$expired
        )
        .map { voted, expired in
            return voted == false && expired == false
        }
        .assign(to: &viewModel.$isVotable)

        poll.$votesCount
            .assign(to: \.voteCount, on: viewModel)
            .store(in: &disposeBag)

        poll.$votersCount
            .assign(to: \.voterCount, on: viewModel)
            .store(in: &disposeBag)

        poll.$expiresAt
            .assign(to: \.expireAt, on: viewModel)
            .store(in: &disposeBag)
        
        poll.$expired
            .assign(to: \.expired, on: viewModel)
            .store(in: &disposeBag)
        
        poll.$voted
            .map { $0 == true }
            .assign(to: \.isVoting, on: viewModel)
            .store(in: &disposeBag)
    }

    private func configureCard(status: MastodonStatus) {
        let status = status.reblog ?? status
        if viewModel.mediaViewConfigurations.isEmpty {
            viewModel.card = status.entity.card
        } else {
            viewModel.card = nil
        }
    }
    
    private func configureToolbar(status: MastodonStatus) {
        let status = status.reblog ?? status

        viewModel.replyCount = status.entity.repliesCount ?? 0
        
        viewModel.reblogCount = status.entity.reblogsCount
        
        viewModel.favoriteCount = status.entity.favouritesCount
        
        viewModel.editedAt = status.entity.editedAt

        // relationship
        viewModel.isReblog = status.entity.reblogged == true
        viewModel.isFavorite = status.entity.favourited == true
        viewModel.isBookmark = status.entity.bookmarked == true
    }
    
    private func configureFilter(status: MastodonStatus) {
        let status = status.reblog ?? status
        
        guard let content = status.entity.content?.lowercased() else { return }
        
        Publishers.CombineLatest(
            viewModel.$activeFilters,
            viewModel.$filterContext
        )
        .receive(on: StatusView.statusFilterWorkingQueue)
        .map { filters, filterContext in
            var wordFilters: [Mastodon.Entity.Filter] = []
            var nonWordFilters: [Mastodon.Entity.Filter] = []
            for filter in filters {
                guard filter.context.contains(where: { $0 == filterContext }) else { continue }
                if filter.wholeWord {
                    wordFilters.append(filter)
                } else {
                    nonWordFilters.append(filter)
                }
            }

            var needsFilter = FilterStatus.notFiltered
            for filter in nonWordFilters {
                guard content.contains(filter.phrase.lowercased()) else { continue }
                needsFilter = .filtered(filter.phrase)
                break
            }

            switch needsFilter {
            case .notFiltered:
                break
            default:
                return needsFilter
            }

            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = content
            let phraseWords = wordFilters.map { $0.phrase.lowercased() }
            tokenizer.enumerateTokens(in: content.startIndex..<content.endIndex) { range, _ in
                let word = String(content[range])
                if phraseWords.contains(word) {
                    needsFilter = .filtered(word)
                    return false
                } else {
                    return true
                }
            }

            return needsFilter
        }
        .receive(on: DispatchQueue.main)
        .assign(to: \.isFiltered, on: viewModel)
        .store(in: &disposeBag)
    }

}
