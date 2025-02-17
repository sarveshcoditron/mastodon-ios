//
//  UserListViewModel+State.swift
//  Mastodon
//
//  Created by MainasuK on 2022-5-17.
//

import Foundation
import GameplayKit
import MastodonSDK
import MastodonCore

extension UserListViewModel {
    class State: GKState {

        let id = UUID()
        
        weak var viewModel: UserListViewModel?
        
        init(viewModel: UserListViewModel) {
            self.viewModel = viewModel
        }
        
        @MainActor
        func enter(state: State.Type) {
            stateMachine?.enter(state)
        }
    }
}

extension UserListViewModel.State {
    class Initial: UserListViewModel.State {
        override func isValidNextState(_ stateClass: AnyClass) -> Bool {
            guard viewModel != nil else { return false }
            switch stateClass {
            case is Reloading.Type:
                return true
            default:
                return false
            }
        }
    }
    
    class Reloading: UserListViewModel.State {
        override func isValidNextState(_ stateClass: AnyClass) -> Bool {
            switch stateClass {
            case is Loading.Type:
                return true
            default:
                return false
            }
        }
        
        override func didEnter(from previousState: GKState?) {
            super.didEnter(from: previousState)
            guard let viewModel, let stateMachine else { return }
            
            // reset
            viewModel.accounts = []
            viewModel.relationships = []

            stateMachine.enter(Loading.self)
        }
    }
    
    class Fail: UserListViewModel.State {
        
        override func isValidNextState(_ stateClass: AnyClass) -> Bool {
            switch stateClass {
            case is Loading.Type:
                return true
            default:
                return false
            }
        }
        
        override func didEnter(from previousState: GKState?) {
            super.didEnter(from: previousState)
            guard viewModel != nil, let stateMachine else { return }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                stateMachine.enter(Loading.self)
            }
        }
    }
    
    class Idle: UserListViewModel.State {
        override func isValidNextState(_ stateClass: AnyClass) -> Bool {
            switch stateClass {
            case is Reloading.Type, is Loading.Type:
                return true
            default:
                return false
            }
        }
    }
    
    class Loading: UserListViewModel.State {
        
        var maxID: String?
        
        override func isValidNextState(_ stateClass: AnyClass) -> Bool {
            switch stateClass {
            case is Fail.Type:
                return true
            case is Idle.Type:
                return true
            case is NoMore.Type:
                return true
            default:
                return false
            }
        }
        
        override func didEnter(from previousState: GKState?) {
            super.didEnter(from: previousState)
            
            if previousState is Reloading {
                maxID = nil
            }
            
            guard let viewModel else { return }
            
            let maxID = self.maxID
            let authenticationBox = viewModel.authenticationBox

            Task {
                do {
                    let accountResponse: Mastodon.Response.Content<[Mastodon.Entity.Account]>
                    switch viewModel.kind {
                    case .favoritedBy(let status):
                        accountResponse = try await APIService.shared.favoritedBy(
                            status: status,
                            query: .init(maxID: maxID, limit: nil),
                            authenticationBox: authenticationBox
                        )
                    case .rebloggedBy(let status):
                        accountResponse = try await APIService.shared.rebloggedBy(
                            status: status,
                            query: .init(maxID: maxID, limit: nil),
                            authenticationBox: authenticationBox
                        )
                    }

                    if accountResponse.value.isEmpty {
                        await enter(state: NoMore.self)

                        viewModel.accounts = []
                        viewModel.relationships = []
                        return
                    }

                    var hasNewAppend = false

                    let newRelationships = try await APIService.shared.relationship(forAccounts: accountResponse.value, authenticationBox: viewModel.authenticationBox)

                    var accounts = viewModel.accounts

                    for user in accountResponse.value {
                        guard accounts.contains(user) == false else { continue }
                        accounts.append(user)
                        hasNewAppend = true
                    }

                    var relationships = viewModel.relationships

                    for relationship in newRelationships.value {
                        guard relationships.contains(relationship) == false else { continue }
                        relationships.append(relationship)
                    }

                    let maxID = accountResponse.link?.maxID

                    if hasNewAppend, maxID != nil {
                        await enter(state: Idle.self)
                    } else {
                        await enter(state: NoMore.self)
                    }

                    viewModel.accounts = accounts
                    viewModel.relationships = relationships
                    self.maxID = maxID

                } catch {
                    await enter(state: Fail.self)
                }
            }   // end Task
        }   // end func didEnter
    }
    
    class NoMore: UserListViewModel.State {
        override func isValidNextState(_ stateClass: AnyClass) -> Bool {
            switch stateClass {
            case is Reloading.Type:
                return true
            default:
                return false
            }
        }
        
        override func didEnter(from previousState: GKState?) {
            super.didEnter(from: previousState)
            
            guard let viewModel else { return }
            // trigger reload
            viewModel.accounts = viewModel.accounts
        }
    }
}
