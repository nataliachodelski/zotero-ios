//
//  MasterCoordinator.swift
//  Zotero
//
//  Created by Michal Rentka on 08.03.2023.
//  Copyright © 2023 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

protocol MasterToMasterTopCoordinatorDelegate: AnyObject {
    func didChange(toLibraryId libraryId: LibraryIdentifier, collectionId: CollectionIdentifier)
}

final class MasterCoordinator {
    private let controllers: Controllers
    private unowned let mainController: MainViewController

    private(set) var topCoordinator: MasterTopCoordinator!

    init(mainController: MainViewController, controllers: Controllers) {
        self.mainController = mainController
        self.controllers = controllers
    }

    func start() {
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            self.startPad()
        default:
            self.startPhone()
        }
    }

    private func startPad() {
        guard let dbStorage = self.controllers.userControllers?.dbStorage else { return }
        
        let masterController = UINavigationController()
        let masterCoordinator = MasterTopCoordinator(navigationController: masterController, mainCoordinatorDelegate: self.mainController, controllers: self.controllers)
        masterCoordinator.coordinatorDelegate = self
        masterCoordinator.start(animated: false)
        self.topCoordinator = masterCoordinator

        let state = TagFilterState(libraryId: Defaults.shared.selectedLibrary, collectionId: Defaults.shared.selectedCollectionId, selectedTags: [])
        let handler = TagFilterActionHandler(dbStorage: dbStorage)
        let viewModel = ViewModel(initialState: state, handler: handler)
        let tagController = TagFilterViewController(viewModel: viewModel)

        let containerController = MasterContainerViewController(topController: masterController, bottomController: tagController)
        self.mainController.viewControllers = [containerController]
    }

    private func startPhone() {
        let masterController = UINavigationController()
        let masterCoordinator = MasterTopCoordinator(navigationController: masterController, mainCoordinatorDelegate: self.mainController, controllers: self.controllers)
        masterCoordinator.coordinatorDelegate = self
        masterCoordinator.start(animated: false)
        self.topCoordinator = masterCoordinator

        self.mainController.viewControllers = [masterController]
    }
}

extension MasterCoordinator: MasterToMasterTopCoordinatorDelegate {
    func didChange(toLibraryId libraryId: LibraryIdentifier, collectionId: CollectionIdentifier) {
        guard let containerController = self.mainController.viewControllers.first as? MasterContainerViewController,
              let tagController = containerController.bottomController as? TagFilterViewController else { return }
        tagController.change(to: libraryId, collectionId: collectionId)
    }
}
