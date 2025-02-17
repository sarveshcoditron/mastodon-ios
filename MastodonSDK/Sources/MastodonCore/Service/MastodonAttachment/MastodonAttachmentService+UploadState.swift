//
//  MastodonAttachmentService+UploadState.swift
//  Mastodon
//
//  Created by MainasuK Cirno on 2021-3-18.
//

import Foundation
import Combine
import GameplayKit
import MastodonSDK

extension MastodonAttachmentService {
    public class UploadState: GKState {
        weak var service: MastodonAttachmentService?
        
        init(service: MastodonAttachmentService) {
            self.service = service
        }
        
        @MainActor
        public override func didEnter(from previousState: GKState?) {
            service?.uploadStateMachineSubject.send(self)
        }
    }
}

extension MastodonAttachmentService.UploadState {
    
    public class Initial: MastodonAttachmentService.UploadState {
        public override func isValidNextState(_ stateClass: AnyClass) -> Bool {
            guard service?.authenticationBox != nil else { return false }
            if stateClass == Initial.self {
                return true
            }

            if service?.file.value != nil {
                return stateClass == Uploading.self
            } else {
                return stateClass == Fail.self
            }
        }
    }
    
    public class Uploading: MastodonAttachmentService.UploadState {
        var needsFallback = false

        public override func isValidNextState(_ stateClass: AnyClass) -> Bool {
            return stateClass == Fail.self
                || stateClass == Finish.self
                || stateClass == Uploading.self
                || stateClass == Processing.self
        }
        
        @MainActor
        public override func didEnter(from previousState: GKState?) {
            super.didEnter(from: previousState)
            
            guard let service = service, let stateMachine = stateMachine else { return }
            guard let authenticationBox = service.authenticationBox else { return }
            guard let file = service.file.value else { return }
            
            let description = service.description.value
            let query = Mastodon.API.Media.UploadMediaQuery(
                file: file,
                thumbnail: nil,
                description: description,
                focus: nil
            )

            // and needs clone the `query` if needs retry
            APIService.shared.uploadMedia(
                domain: authenticationBox.domain,
                query: query,
                mastodonAuthenticationBox: authenticationBox,
                needsFallback: needsFallback
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                guard let self = self else { return }
                switch completion {
                case .failure(let error):
                    if let apiError = error as? Mastodon.API.Error,
                       apiError.httpResponseStatus == .notFound,
                       self.needsFallback == false
                    {
                        self.needsFallback = true
                        stateMachine.enter(Uploading.self)
                    } else {
                        service.error.send(error)
                        stateMachine.enter(Fail.self)
                    }
                case .finished:
                    break
                }
            } receiveValue: { response in
                service.attachment.value = response.value
                if response.statusCode == 202 {
                    // check if still processing
                    stateMachine.enter(Processing.self)
                } else {
                    stateMachine.enter(Finish.self)
                }
            }
            .store(in: &service.disposeBag)
        }
    }
    
    public class Processing: MastodonAttachmentService.UploadState {
        
        static let retryLimit = 10
        var retryCount = 0
        
        public override func isValidNextState(_ stateClass: AnyClass) -> Bool {
            return stateClass == Fail.self || stateClass == Finish.self || stateClass == Processing.self
        }
        
        public override func didEnter(from previousState: GKState?) {
            super.didEnter(from: previousState)
            
            guard let service = service, let stateMachine = stateMachine else { return }
            guard let authenticationBox = service.authenticationBox else { return }
            guard let attachment = service.attachment.value else { return }
         
            retryCount += 1
            guard retryCount < Processing.retryLimit else {
                stateMachine.enter(Fail.self)
                return
            }
         
            APIService.shared.getMedia(
                attachmentID: attachment.id,
                mastodonAuthenticationBox: authenticationBox
            )
            .retry(3)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                guard let _ = self else { return }
                switch completion {
                case .failure(let error):
                    service.error.send(error)
                    stateMachine.enter(Fail.self)
                case .finished:
                    break
                }
            } receiveValue: { [weak self] response in
                guard let self = self else { return }
                guard let _ = response.value.url else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.stateMachine?.enter(Processing.self)
                    }
                    return
                }
                
                stateMachine.enter(Finish.self)
            }
            .store(in: &service.disposeBag)
        }
    }
    
    public class Fail: MastodonAttachmentService.UploadState {
        public override func isValidNextState(_ stateClass: AnyClass) -> Bool {
            // allow discard publishing
            return stateClass == Uploading.self || stateClass == Finish.self
        }
    }
    
    public class Finish: MastodonAttachmentService.UploadState {
        public override func isValidNextState(_ stateClass: AnyClass) -> Bool {
            return false
        }
    }
    
}

