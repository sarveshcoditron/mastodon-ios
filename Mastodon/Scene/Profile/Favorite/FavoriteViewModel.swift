//
//  FavoriteViewModel.swift
//  Mastodon
//
//  Created by MainasuK Cirno on 2021-4-6.
//

import UIKit
import Combine
import CoreData
import CoreDataStack
import GameplayKit
import MastodonCore

final class FavoriteViewModel {
    
    var disposeBag = Set<AnyCancellable>()
    
    // input
    let context: AppContext
    let authenticationBox: MastodonAuthenticationBox
    let dataController: StatusDataController

    // output
    var diffableDataSource: UITableViewDiffableDataSource<StatusSection, StatusItem>?
    private(set) lazy var stateMachine: GKStateMachine = {
        let stateMachine = GKStateMachine(states: [
            State.Initial(viewModel: self),
            State.Reloading(viewModel: self),
            State.Fail(viewModel: self),
            State.Idle(viewModel: self),
            State.Loading(viewModel: self),
            State.NoMore(viewModel: self),
        ])
        stateMachine.enter(State.Initial.self)
        return stateMachine
    }()
    
    @MainActor
    init(context: AppContext, authenticationBox: MastodonAuthenticationBox) {
        self.context = context
        self.authenticationBox = authenticationBox
        self.dataController = StatusDataController()
    }
    
}
